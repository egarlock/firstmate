#!/usr/bin/env python3
"""fm-board-server.py - localhost web board for firstmate's task backlog.

A rudimentary, Trello-like web view of firstmate's backlog with four lanes:
Suggested, Todo/Queued, In Progress, and Completed. It is a thin, read-mostly
UI over firstmate's existing task data - it does NOT invent a second source of
truth:

  - Queued / In flight / Done come from data/backlog.md, which IS the tasks-axi
    markdown backend's on-disk file (dependency-free to read, canonical).
  - Suggested comes from a separate, local, gitignored data/board-suggestions.json
    so suggestions never collide with tasks-axi's own ids or file.

Mutations are deliberately narrow and safe:
  - reorder: reorders only the Queued section's blocks in data/backlog.md, the
    durable order firstmate reads top-to-bottom when selecting ready work. It is
    permutation-validated (same id set in, same set out) so the UI can never
    silently add, drop, or rewrite In flight / Done state.
  - promote: turns a suggestion into a real Queued backlog item through the
    existing backlog contract (`tasks-axi add`, markdown-append fallback), and
    removes the suggestion only after that add succeeds.
  - suggest: appends a suggestion to the local suggestions file.

Every write is atomic (temp file + os.replace) and confined to
data/backlog.md and data/board-suggestions.json. The HTTP server binds only to
a loopback address and rejects any non-loopback client, so there is no
unauthenticated write API exposed to the network. Standard library only.

The module doubles as a CLI so tests (and humans) can exercise the exact same
logic without HTTP:

  fm-board-server.py board                 # board JSON to stdout
  fm-board-server.py task <id>             # one task's full context JSON
  fm-board-server.py reorder <id,id,...>   # reorder the Queued section
  fm-board-server.py promote <suggestion-id>
  fm-board-server.py add-suggestion --title T [--project P] [--kind K] [--note N]
  fm-board-server.py serve [--host H] [--port N]

Environment (set by bin/fm-board.sh; sensible defaults otherwise):
  FM_HOME   firstmate home (default: repo root, i.e. this file's ../..)
  FM_DATA   data dir       (default: $FM_HOME/data)
  FM_STATE  state dir      (default: $FM_HOME/state)
  FM_BOARD_TASKS_AXI  tasks-axi executable (default: "tasks-axi" on PATH)
  FM_BOARD_TASKS_FILE forced backlog path for tasks-axi --file (default: unset)
"""

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --- environment resolution -------------------------------------------------

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)


def _env_home():
    return os.environ.get("FM_HOME") or REPO_ROOT


def _data_dir():
    return os.environ.get("FM_DATA") or os.path.join(_env_home(), "data")


def _state_dir():
    return os.environ.get("FM_STATE") or os.path.join(_env_home(), "state")


def _backlog_path():
    return os.path.join(_data_dir(), "backlog.md")


def _suggestions_path():
    return os.path.join(_data_dir(), "board-suggestions.json")


def _asset_path():
    return os.path.join(HERE, "fm-board.html")


# Task/suggestion ids: lowercase kebab, must start alphanumeric. Matches the
# short kebab slugs firstmate and tasks-axi use, and keeps ids safe to embed in
# filesystem paths (no traversal, no separators).
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

# Section headers in the backlog markdown.
SECTION_INFLIGHT = "In flight"
SECTION_QUEUED = "Queued"
SECTION_DONE = "Done"

URL_RE = re.compile(r"https?://[^\s)]+")


class BoardError(Exception):
    """A validation / operation error surfaced as a clean 4xx to the client."""

    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status
        self.message = message


# --- atomic write -----------------------------------------------------------


def _atomic_write(path, text):
    """Write text to path atomically: temp file in the same dir, then replace."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".fm-board.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --- backlog markdown parsing ----------------------------------------------
#
# The backlog is a sequence of "## <section>" headers, each followed by bullet
# lines ("- ...") for its items. A bullet may be followed by 2-space-indented
# continuation lines which are the item's body/notes. We parse each item into a
# block: its bullet line plus any continuation lines, so reordering can move an
# item together with its notes.


def _read_backlog_lines():
    path = _backlog_path()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read().splitlines()
    except FileNotFoundError:
        return []


def _is_section_header(line):
    m = re.match(r"^##\s+(.*?)\s*$", line)
    return m.group(1) if m else None


def _is_bullet(line):
    return re.match(r"^\s*-\s+", line) is not None


def _is_continuation(line):
    # A non-empty line that is indented and not itself a bullet belongs to the
    # preceding item as a body/notes line.
    if not line.strip():
        return False
    if _is_bullet(line):
        return False
    return line[:1].isspace()


def _iter_section_blocks(lines, section):
    """Yield (start_idx, block_lines) for each item block in a section.

    block_lines[0] is the bullet line; the rest are its continuation lines.
    """
    in_section = False
    i = 0
    n = len(lines)
    while i < n:
        header = _is_section_header(lines[i])
        if header is not None:
            in_section = header == section
            i += 1
            continue
        if in_section and _is_bullet(lines[i]):
            start = i
            block = [lines[i]]
            i += 1
            while i < n and _is_continuation(lines[i]):
                block.append(lines[i])
                i += 1
            yield start, block
            continue
        i += 1


def _parse_item(block, section):
    """Turn a block (bullet + continuation lines) into a card dict."""
    bullet = block[0]
    body_lines = [ln.strip() for ln in block[1:] if ln.strip()]
    body = "\n".join(body_lines)

    # Strip the leading "- ", optional checkbox "[ ] "/"[x] ", and optional
    # "**id**" bold wrapper, to expose "<id> - <title> ...".
    text = re.sub(r"^\s*-\s+", "", bullet)
    text = re.sub(r"^\[[ xX]\]\s+", "", text)
    text = re.sub(r"^\*\*(.+?)\*\*", r"\1", text)

    # id is the first token; the remainder (after " - ") is the descriptor.
    m = re.match(r"^(\S+)\s*-\s*(.*)$", text)
    if m:
        item_id = m.group(1)
        rest = m.group(2)
    else:
        item_id = text.split()[0] if text.split() else ""
        rest = ""

    repo = _extract_paren(rest, "repo")
    kind = _extract_paren(rest, "kind")
    since = _extract_paren(rest, "since", bare=True)
    merged = _extract_paren(rest, "merged", bare=True)
    reported = _extract_paren(rest, "reported", bare=True)

    blocked_by = []
    bm = re.search(r"blocked-by:\s*([a-z0-9-]+)", rest)
    if bm:
        blocked_by.append(bm.group(1))

    links = URL_RE.findall(rest) + URL_RE.findall(body)
    # A local report path is a useful "link" too.
    report_ref = None
    rp = re.search(r"(data/[A-Za-z0-9._/-]+report\.md)", rest + " " + body)
    if rp:
        report_ref = rp.group(1)

    # Title = descriptor with the trailing metadata stripped off.
    title = rest
    title = re.sub(r"\bblocked-by:\s*[a-z0-9-]+", "", title)
    title = URL_RE.sub("", title)
    title = re.sub(r"\((?:repo|kind|since|merged|reported)[^)]*\)", "", title)
    if report_ref:
        title = title.replace(report_ref, "")
    title = re.sub(r"\s*-\s*$", "", title)
    title = re.sub(r"\s{2,}", " ", title).strip(" -\t")

    date = since or merged or reported

    return {
        "id": item_id,
        "title": title,
        "repo": repo,
        "kind": kind,
        "blocked_by": blocked_by,
        "links": _dedupe(links),
        "report": report_ref,
        "date": date,
        "notes": body,
        "section": section,
    }


def _extract_paren(text, key, bare=False):
    """Extract "(key: value)" or, when bare, "(key value)"."""
    if bare:
        m = re.search(r"\(" + re.escape(key) + r"\s+([^)]+)\)", text)
    else:
        m = re.search(r"\(" + re.escape(key) + r":\s*([^)]+)\)", text)
    return m.group(1).strip() if m else None


def _dedupe(seq):
    seen = set()
    out = []
    for item in seq:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def parse_section(section):
    """Return the list of card dicts for a backlog section, in file order."""
    lines = _read_backlog_lines()
    items = []
    for _start, block in _iter_section_blocks(lines, section):
        item = _parse_item(block, section)
        if item["id"]:
            items.append(item)
    return items


# --- suggestions store ------------------------------------------------------


def _slugify(text):
    slug = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    slug = slug[:32].strip("-")
    return slug or "idea"


def read_suggestions():
    path = _suggestions_path()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return []
    except (ValueError, OSError):
        return []
    if isinstance(data, dict) and isinstance(data.get("suggestions"), list):
        data = data["suggestions"]
    if not isinstance(data, list):
        return []
    out = []
    for entry in data:
        if not isinstance(entry, dict):
            continue
        sid = str(entry.get("id") or "").strip()
        title = str(entry.get("title") or "").strip()
        if not title:
            continue
        if not sid or not ID_RE.match(sid):
            sid = _unique_suggestion_id(_slugify(title), [o["id"] for o in out])
        out.append(
            {
                "id": sid,
                "title": title,
                "project": str(entry.get("project") or "").strip() or None,
                "kind": (str(entry.get("kind") or "").strip() or "ship"),
                "note": str(entry.get("note") or "").strip() or None,
                "section": "Suggested",
            }
        )
    return out


def _unique_suggestion_id(base, existing):
    existing = set(existing)
    if base not in existing:
        return base
    i = 2
    while f"{base}-{i}" in existing:
        i += 1
    return f"{base}-{i}"


def write_suggestions(suggestions):
    payload = [
        {
            "id": s["id"],
            "title": s["title"],
            "project": s.get("project"),
            "kind": s.get("kind") or "ship",
            "note": s.get("note"),
        }
        for s in suggestions
    ]
    _atomic_write(_suggestions_path(), json.dumps(payload, indent=2) + "\n")


def add_suggestion(title, project=None, kind="ship", note=None):
    title = (title or "").strip()
    if not title:
        raise BoardError("suggestion title is required")
    kind = (kind or "ship").strip() or "ship"
    if kind not in ("ship", "scout"):
        raise BoardError("suggestion kind must be 'ship' or 'scout'")
    suggestions = read_suggestions()
    sid = _unique_suggestion_id(_slugify(title), [s["id"] for s in suggestions])
    entry = {
        "id": sid,
        "title": title,
        "project": (project or "").strip() or None,
        "kind": kind,
        "note": (note or "").strip() or None,
        "section": "Suggested",
    }
    suggestions.append(entry)
    write_suggestions(suggestions)
    return entry


# --- board assembly ---------------------------------------------------------


def build_board():
    return {
        "suggested": read_suggestions(),
        "queued": parse_section(SECTION_QUEUED),
        "in_flight": parse_section(SECTION_INFLIGHT),
        "done": parse_section(SECTION_DONE),
    }


# --- task detail (modal) ----------------------------------------------------


def _read_file(path, limit=200_000):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read(limit)
    except (FileNotFoundError, IsADirectoryError, OSError):
        return None


def _read_status(item_id):
    path = os.path.join(_state_dir(), item_id + ".status")
    text = _read_file(path)
    if text is None:
        return None
    lines = [ln for ln in text.splitlines() if ln.strip()]
    return "\n".join(lines) if lines else None


def _read_meta(item_id):
    path = os.path.join(_state_dir(), item_id + ".meta")
    text = _read_file(path)
    if text is None:
        return None
    meta = {}
    for line in text.splitlines():
        if "=" in line:
            key, _, val = line.partition("=")
            meta[key.strip()] = val.strip()
    return meta or None


def build_task_detail(item_id):
    if not ID_RE.match(item_id or ""):
        raise BoardError("invalid task id")

    # Find the card in whichever section it lives in.
    card = None
    for section in (SECTION_QUEUED, SECTION_INFLIGHT, SECTION_DONE):
        for item in parse_section(section):
            if item["id"] == item_id:
                card = item
                break
        if card:
            break

    if card is None:
        for sug in read_suggestions():
            if sug["id"] == item_id:
                card = dict(sug)
                card.setdefault("notes", sug.get("note") or "")
                break

    detail = {
        "id": item_id,
        "found": card is not None,
        "card": card,
        # Every source is represented explicitly; missing ones are null, so the
        # UI degrades cleanly rather than the whole page failing.
        "backlog_notes": card.get("notes") if card else None,
        "status": _read_status(item_id),
        "brief": _read_file(os.path.join(_data_dir(), item_id, "brief.md")),
        "plan": _read_file(os.path.join(_data_dir(), item_id, "plan.md")),
        "report": _read_file(os.path.join(_data_dir(), item_id, "report.md")),
        "meta": _read_meta(item_id),
    }
    if card:
        detail["blocked_by"] = card.get("blocked_by", [])
        detail["links"] = card.get("links", [])
        detail["report_link"] = card.get("report")
        detail["date"] = card.get("date")
        detail["section"] = card.get("section")
    return detail


# --- reorder the Queued section --------------------------------------------


def reorder_queued(new_order):
    """Reorder the Queued section's item blocks to match new_order.

    new_order must be a permutation of the current Queued ids (same set). This
    guarantees the UI can only reprioritize; it can never add, drop, or edit an
    item, and it never touches In flight / Done. Returns the resulting id list.
    """
    if not isinstance(new_order, list) or not all(isinstance(x, str) for x in new_order):
        raise BoardError("order must be a list of ids")

    lines = _read_backlog_lines()
    blocks = list(_iter_section_blocks(lines, SECTION_QUEUED))
    current_ids = [_parse_item(b, SECTION_QUEUED)["id"] for _s, b in blocks]

    if sorted(new_order) != sorted(current_ids):
        raise BoardError(
            "order must be a permutation of the current queued ids "
            f"(have {current_ids}, got {new_order})"
        )
    if len(set(new_order)) != len(new_order):
        raise BoardError("order contains duplicate ids")

    # Map id -> block lines, then splice blocks back in the requested order at
    # the position of the first block, dropping the originals.
    block_by_id = {}
    for (_start, block) in blocks:
        item_id = _parse_item(block, SECTION_QUEUED)["id"]
        block_by_id[item_id] = block

    # Indices occupied by any queued block line.
    occupied = set()
    for start, block in blocks:
        for offset in range(len(block)):
            occupied.add(start + offset)

    if not blocks:
        return current_ids  # nothing to do

    first_start = blocks[0][0]
    reordered = []
    for item_id in new_order:
        reordered.extend(block_by_id[item_id])

    out = []
    inserted = False
    for idx, line in enumerate(lines):
        if idx in occupied:
            if not inserted and idx == first_start:
                out.extend(reordered)
                inserted = True
            # skip all original queued block lines
            continue
        out.append(line)
    if not inserted:  # defensive; blocks existed so this should not happen
        out.extend(reordered)

    _atomic_write(_backlog_path(), "\n".join(out) + "\n")
    return new_order


# --- promote a suggestion to Queued ----------------------------------------


def _tasks_axi_cmd():
    return os.environ.get("FM_BOARD_TASKS_AXI") or "tasks-axi"


def _backlog_ids():
    ids = set()
    for section in (SECTION_QUEUED, SECTION_INFLIGHT, SECTION_DONE):
        for item in parse_section(section):
            ids.add(item["id"])
    return ids


def _unique_task_id(base):
    base = _slugify(base)
    existing = _backlog_ids()
    if base not in existing:
        return base
    i = 2
    while f"{base}-{i}" in existing:
        i += 1
    return f"{base}-{i}"


def _append_queued_markdown(item_id, title, kind, repo):
    """Fallback: append a canonical Queued bullet directly (hand-edit contract)."""
    lines = _read_backlog_lines()
    if not lines:
        lines = ["# Backlog", "", "## In flight", "## Queued", "## Done"]
    bullet = f"- [ ] {item_id} - {title}"
    if repo:
        bullet += f" (repo: {repo})"
    bullet += f" (kind: {kind})"

    out = []
    inserted = False
    i = 0
    n = len(lines)
    while i < n:
        out.append(lines[i])
        if _is_section_header(lines[i]) == SECTION_QUEUED and not inserted:
            # Insert after the last existing queued block (or right here).
            i += 1
            while i < n and not lines[i].startswith("## "):
                out.append(lines[i])
                i += 1
            out.append(bullet)
            inserted = True
            continue
        i += 1
    if not inserted:
        out.append("## Queued")
        out.append(bullet)
    _atomic_write(_backlog_path(), "\n".join(out) + "\n")


def promote_suggestion(suggestion_id):
    """Create a Queued backlog item from a suggestion, then drop the suggestion.

    The backlog item is created through the existing backlog contract
    (`tasks-axi add`, or a canonical markdown append when tasks-axi is
    unavailable). The suggestion is removed only after the add succeeds, so a
    failed add never loses the suggestion.
    """
    if not ID_RE.match(suggestion_id or ""):
        raise BoardError("invalid suggestion id")

    suggestions = read_suggestions()
    match = None
    for sug in suggestions:
        if sug["id"] == suggestion_id:
            match = sug
            break
    if match is None:
        raise BoardError("suggestion not found", status=404)

    kind = match.get("kind") or "ship"
    repo = match.get("project")
    title = match["title"]
    task_id = _unique_task_id(match["id"])

    created_via = _create_queued_item(task_id, title, kind, repo)

    # Add succeeded: now remove the suggestion atomically.
    remaining = [s for s in suggestions if s["id"] != suggestion_id]
    write_suggestions(remaining)

    return {"task_id": task_id, "via": created_via, "title": title, "kind": kind, "repo": repo}


def _create_queued_item(task_id, title, kind, repo):
    axi = _tasks_axi_cmd()
    cmd = [axi, "add", task_id, title, "--kind", kind, "--json"]
    if repo:
        cmd += ["--repo", repo]
    tasks_file = os.environ.get("FM_BOARD_TASKS_FILE")
    if tasks_file:
        cmd += ["--file", tasks_file]
    try:
        proc = subprocess.run(
            cmd,
            cwd=_env_home(),
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (FileNotFoundError, OSError):
        # tasks-axi not installed: fall back to the sanctioned markdown edit.
        _append_queued_markdown(task_id, title, kind, repo)
        return "markdown"
    except subprocess.TimeoutExpired:
        raise BoardError("tasks-axi add timed out", status=502)

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise BoardError(f"tasks-axi add failed: {detail}", status=502)
    return "tasks-axi"


# --- HTTP server ------------------------------------------------------------


def _is_loopback(addr):
    try:
        return ipaddress.ip_address(addr).is_loopback
    except ValueError:
        return False


class BoardHandler(BaseHTTPRequestHandler):
    server_version = "fm-board/1.0"

    # Quieter logging: one concise line to stderr.
    def log_message(self, fmt, *args):
        sys.stderr.write("fm-board: %s - %s\n" % (self.address_string(), fmt % args))

    # Defense in depth: refuse any client that is not on the loopback interface,
    # even if the socket were somehow bound more broadly.
    def _guard_loopback(self):
        client = self.client_address[0] if self.client_address else ""
        if not _is_loopback(client):
            self._send_json({"error": "forbidden: loopback only"}, status=403)
            return False
        return True

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, text, status=200):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        if length > 1_000_000:
            raise BoardError("request body too large", status=413)
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise BoardError("invalid JSON body")
        if not isinstance(data, dict):
            raise BoardError("JSON body must be an object")
        return data

    def do_GET(self):
        if not self._guard_loopback():
            return
        try:
            if self.path == "/" or self.path == "/index.html":
                html = _read_file(_asset_path())
                if html is None:
                    self._send_json({"error": "board asset missing"}, status=500)
                    return
                self._send_html(html)
                return
            if self.path == "/api/board":
                self._send_json(build_board())
                return
            m = re.match(r"^/api/task/([a-z0-9][a-z0-9-]*)$", self.path)
            if m:
                self._send_json(build_task_detail(m.group(1)))
                return
            self._send_json({"error": "not found"}, status=404)
        except BoardError as err:
            self._send_json({"error": err.message}, status=err.status)
        except Exception as err:  # pragma: no cover - defensive
            self._send_json({"error": "internal error: %s" % err}, status=500)

    def do_POST(self):
        if not self._guard_loopback():
            return
        try:
            data = self._read_json_body()
            if self.path == "/api/reorder":
                order = data.get("order")
                result = reorder_queued(order)
                self._send_json({"ok": True, "order": result})
                return
            if self.path == "/api/promote":
                result = promote_suggestion(str(data.get("id") or ""))
                self._send_json({"ok": True, "promoted": result})
                return
            if self.path == "/api/suggest":
                entry = add_suggestion(
                    title=data.get("title"),
                    project=data.get("project"),
                    kind=data.get("kind") or "ship",
                    note=data.get("note"),
                )
                self._send_json({"ok": True, "suggestion": entry})
                return
            self._send_json({"error": "not found"}, status=404)
        except BoardError as err:
            self._send_json({"error": err.message}, status=err.status)
        except Exception as err:  # pragma: no cover - defensive
            self._send_json({"error": "internal error: %s" % err}, status=500)


def serve(host, port):
    if not _is_loopback(host):
        raise SystemExit(
            f"fm-board: refusing to bind non-loopback host {host!r}; use 127.0.0.1"
        )
    httpd = ThreadingHTTPServer((host, port), BoardHandler)
    bound_host, bound_port = httpd.server_address[:2]
    sys.stderr.write(f"fm-board: serving on http://{bound_host}:{bound_port}\n")
    sys.stderr.write(f"fm-board: backlog {_backlog_path()}\n")
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


# --- CLI --------------------------------------------------------------------


def _print_json(obj):
    print(json.dumps(obj, indent=2))


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(description="firstmate task board")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("board", help="print the board JSON")

    p_task = sub.add_parser("task", help="print one task's full context")
    p_task.add_argument("id")

    p_reorder = sub.add_parser("reorder", help="reorder the Queued section")
    p_reorder.add_argument("order", help="comma-separated queued ids in new order")

    p_promote = sub.add_parser("promote", help="promote a suggestion to Queued")
    p_promote.add_argument("id")

    p_add = sub.add_parser("add-suggestion", help="add a suggestion")
    p_add.add_argument("--title", required=True)
    p_add.add_argument("--project", default=None)
    p_add.add_argument("--kind", default="ship")
    p_add.add_argument("--note", default=None)

    p_serve = sub.add_parser("serve", help="run the HTTP server")
    p_serve.add_argument("--host", default="127.0.0.1")
    p_serve.add_argument("--port", type=int, default=8787)

    args = parser.parse_args(argv)

    try:
        if args.cmd == "board" or args.cmd is None:
            _print_json(build_board())
        elif args.cmd == "task":
            _print_json(build_task_detail(args.id))
        elif args.cmd == "reorder":
            order = [x for x in args.order.split(",") if x]
            _print_json({"ok": True, "order": reorder_queued(order)})
        elif args.cmd == "promote":
            _print_json({"ok": True, "promoted": promote_suggestion(args.id)})
        elif args.cmd == "add-suggestion":
            _print_json(
                {
                    "ok": True,
                    "suggestion": add_suggestion(
                        args.title, args.project, args.kind, args.note
                    ),
                }
            )
        elif args.cmd == "serve":
            serve(args.host, args.port)
        else:  # pragma: no cover
            parser.error("unknown command")
    except BoardError as err:
        sys.stderr.write(f"fm-board: {err.message}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

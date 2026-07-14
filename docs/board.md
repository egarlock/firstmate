# The local task board

`bin/fm-board.sh` serves a rudimentary, Trello-like web board over firstmate's
existing backlog. It is a thin, read-mostly UI: it does **not** invent a second
source of truth. Queued / In Progress / Completed come straight from
`data/backlog.md` (the tasks-axi markdown backend), and a separate, local,
gitignored `data/board-suggestions.json` backs the Suggested lane.

The board is meant for eyeballing the queue and lightly reprioritizing it, not
for running the whole workflow. Dispatch, validation, and merges still happen
through firstmate and the crew.

## Launch

```sh
bin/fm-board.sh                 # serve on 127.0.0.1:8787 and open a browser
bin/fm-board.sh --port 9000     # choose a port
bin/fm-board.sh --no-open       # do not open a browser (e.g. over SSH)
```

The server binds **only** to a loopback address. Passing a non-loopback
`--host` is refused, and any non-loopback client is rejected, so the write API
is never exposed to the network. It uses the Python 3 standard library only, so
there is nothing to install.

Stop it with `Ctrl-C`.

## Lanes

| Lane          | Source                             | Meaning                       |
| ------------- | ---------------------------------- | ----------------------------- |
| Suggested     | `data/board-suggestions.json`      | Loose ideas, not yet real work |
| Todo / Queued | backlog `## Queued`                | Queued backlog items          |
| In Progress   | backlog `## In flight`             | Tasks with a live crewmate    |
| Completed     | backlog `## Done`                  | Merged ship tasks, scout reports |

Each card shows the useful summary fields already present in the backlog: title,
id, project (repo), kind, blockers, dates, and PR/report links.

## Card detail modal

Clicking a card opens a centered, accessible modal (Escape or an overlay click
closes it; focus is managed and restored). It gathers the full context available
for that task and represents any missing source cleanly rather than failing the
page:

- summary (lane, project, kind, date, blockers, delivery mode)
- links (PR URLs) and the report path when present
- current status (`state/<id>.status`)
- backlog notes (the item's indented body lines)
- brief, plan, and report (`data/<id>/brief.md`, `plan.md`, `report.md`)

## Reprioritize the queue (drag and drop)

Within the Todo / Queued lane, drag a card onto another to reorder it. The new
order is persisted by physically reordering the item blocks (each bullet plus
its indented notes) inside `data/backlog.md`, which is the same top-to-bottom
order firstmate reads when selecting ready work. Refresh and the order remains.

Reordering is **permutation-validated**: the server only accepts a new order
that is exactly the current set of queued ids, so the UI can never add, drop, or
edit an item, and it never touches In Progress or Completed state. An invalid
request is rejected and the backlog file is left byte-for-byte unchanged.

## Suggestions and promotion

Use **+ New suggestion** in the Suggested lane to jot an idea (title, optional
project, kind, note). Suggestions live only in the local
`data/board-suggestions.json` and never collide with tasks-axi's ids or file.

Open a suggestion and click **Promote to Todo** to turn it into a real Queued
backlog item. Promotion goes through the existing backlog contract
(`tasks-axi add`, with a canonical markdown-append fallback when tasks-axi is
unavailable) and removes the suggestion **only after** the add succeeds, so a
failed promotion never loses the idea.

## Safety model

- Binds `127.0.0.1` only; refuses a non-loopback host and rejects non-loopback
  clients (defense in depth).
- Every write is atomic (temp file in the same directory, then `os.replace`).
- Writes are confined to `data/backlog.md` and `data/board-suggestions.json`.
- Ids are validated (`^[a-z0-9][a-z0-9-]*$`), so they are safe to embed in
  paths; request bodies are size-capped.
- The board never rewrites active or completed task state; only the queue order
  and the local suggestions file are mutable from the UI.

## Under the hood

`bin/fm-board.sh` is a thin launcher that resolves firstmate's environment and
execs `bin/fm-board-server.py`. The server doubles as a CLI so every code path
is testable without HTTP:

```sh
bin/fm-board-server.py board                 # board JSON
bin/fm-board-server.py task <id>             # one task's full context JSON
bin/fm-board-server.py reorder <id,id,...>   # reorder the Queued section
bin/fm-board-server.py promote <suggestion-id>
bin/fm-board-server.py add-suggestion --title T [--project P] [--kind K] [--note N]
```

The frontend is a single self-contained `bin/fm-board.html` (vanilla HTML / CSS
/ JS, no build step, no external assets).

## Follow-up ideas

This is a deliberately rudimentary first version. Reasonable next steps (kept out
of scope here to avoid growing into a full project-management system):

- edit or delete a suggestion in place, and reorder the Suggested lane
- cross-lane drag (e.g. Suggested -> Todo) instead of the modal Promote button
- filter or group cards by project
- live refresh when `data/backlog.md` changes on disk

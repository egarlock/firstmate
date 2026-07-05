# shellcheck shell=bash
# fm-pr-url-lib.sh - the ONE definition of "what PR URLs firstmate accepts".
# Usage: . bin/fm-pr-url-lib.sh
#
# Sourced by bin/fm-pr-check.sh and bin/fm-pr-merge.sh so the two scripts can
# never diverge on URL shape rules. That matters for more than tidiness: the
# URL originates in crewmate-authored status text ("done: PR <url> checks
# green") and fm-pr-check.sh interpolates it into the watcher-EXECUTED
# state/<id>.check.sh, so every accepted character class below is a security
# boundary against command injection, not just a syntax nicety.
#
# Two forges are recognized:
#   github       https://github.com/<owner>/<repo>/pull/<n>
#   azuredevops  https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<n>
#                https://<org>.visualstudio.com/<project>/_git/<repo>/pullrequest/<n>
#                (the legacy visualstudio.com host names the same org; both
#                normalize to the https://dev.azure.com/<org> organization URL
#                the az CLI expects)
# Anything else is unknown and refused with one shared error message.
#
# ADO project/repo segments additionally allow '%' so URL-encoded names (e.g.
# My%20Project) pass; '%' is inert in double quotes and in az arguments, so it
# stays interpolation-safe in the generated check shim.
#
# Idempotent: safe to source more than once. set -u / set -e safe.

if [ -z "${FM_PR_URL_LIB_SOURCED:-}" ]; then
  FM_PR_URL_LIB_SOURCED=1

  # fm_pr_url_parse <url>: classify and extract. On success returns 0 and sets:
  #   FM_PR_KIND    github | azuredevops
  #   FM_PR_NUMBER  the PR number (both kinds)
  #   github:       FM_PR_OWNER, FM_PR_REPO
  #   azuredevops:  FM_PR_ADO_ORG, FM_PR_ADO_PROJECT, FM_PR_ADO_REPO,
  #                 FM_PR_ADO_ORG_URL (always https://dev.azure.com/<org>)
  # On an unknown/unsafe URL: prints the shared shape error to stderr, sets
  # FM_PR_KIND=unknown, and returns 1.
  # The FM_PR_* results are this lib's contract, consumed by the sourcing
  # scripts, so they read as "unused" to a per-file lint pass.
  # shellcheck disable=SC2034
  fm_pr_url_parse() {
    local url=$1
    FM_PR_KIND=unknown
    FM_PR_NUMBER='' FM_PR_OWNER='' FM_PR_REPO=''
    FM_PR_ADO_ORG='' FM_PR_ADO_PROJECT='' FM_PR_ADO_REPO='' FM_PR_ADO_ORG_URL=''
    if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
      # GitHub owner names cannot end in a hyphen; rejecting it here keeps the
      # historical rule from the pre-lib per-script parsers.
      if [[ "${BASH_REMATCH[1]}" != *- ]]; then
        FM_PR_KIND=github
        FM_PR_OWNER="${BASH_REMATCH[1]}"
        FM_PR_REPO="${BASH_REMATCH[2]}"
        FM_PR_NUMBER="${BASH_REMATCH[3]}"
        return 0
      fi
    elif [[ "$url" =~ ^https://dev\.azure\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._%-]+)/_git/([A-Za-z0-9._%-]+)/pullrequest/([0-9]+)/?$ ]]; then
      FM_PR_KIND=azuredevops
      FM_PR_ADO_ORG="${BASH_REMATCH[1]}"
      FM_PR_ADO_PROJECT="${BASH_REMATCH[2]}"
      FM_PR_ADO_REPO="${BASH_REMATCH[3]}"
      FM_PR_NUMBER="${BASH_REMATCH[4]}"
      FM_PR_ADO_ORG_URL="https://dev.azure.com/$FM_PR_ADO_ORG"
      return 0
    elif [[ "$url" =~ ^https://([A-Za-z0-9][A-Za-z0-9-]*)\.visualstudio\.com/([A-Za-z0-9._%-]+)/_git/([A-Za-z0-9._%-]+)/pullrequest/([0-9]+)/?$ ]]; then
      FM_PR_KIND=azuredevops
      FM_PR_ADO_ORG="${BASH_REMATCH[1]}"
      FM_PR_ADO_PROJECT="${BASH_REMATCH[2]}"
      FM_PR_ADO_REPO="${BASH_REMATCH[3]}"
      FM_PR_NUMBER="${BASH_REMATCH[4]}"
      FM_PR_ADO_ORG_URL="https://dev.azure.com/$FM_PR_ADO_ORG"
      return 0
    fi
    echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> or https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<number> (got: $url)" >&2
    return 1
  }

  # fm_ado_preflight: verify the az CLI plus its azure-devops extension are
  # available before an Azure DevOps PR flow starts. Prints an actionable
  # remedy to stderr and returns 1 when either is missing.
  fm_ado_preflight() {
    if ! command -v az >/dev/null 2>&1; then
      echo "error: Azure DevOps PR URLs need the az CLI; install azure-cli, then run: az extension add --name azure-devops && az login" >&2
      return 1
    fi
    if ! az extension show --name azure-devops >/dev/null 2>&1; then
      echo "error: az CLI is missing the azure-devops extension; run: az extension add --name azure-devops (and az login if not signed in)" >&2
      return 1
    fi
    return 0
  }
fi

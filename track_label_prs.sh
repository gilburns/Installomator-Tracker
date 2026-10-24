#!/bin/zsh
#
# Tracks open pull requests on upstream Installomator
# (https://github.com/Installomator/Installomator/pulls) that touch label
# fragments (fragments/labels/<label>.sh), and writes one
# LabelPRs/<label>.json per affected label describing every open PR that
# changes it: who opened it, draft/review/CI/merge state, and what the PR
# does to that label file.
#
# Also writes label_prs.csv, one row per (label, PR) pair.
#
# LabelPRs/ is a current snapshot, mirrored like Labels/: a label's file is
# rewritten whenever its PR data changes, and deleted once no open PR touches
# that label anymore (merged, closed, or the file was dropped from the PR).
#
# Uses the GitHub GraphQL API via `gh`, so it needs an authenticated gh (or
# GH_TOKEN set, as in the workflow). PRs touching more than 100 files have
# their file list completed through the REST API.
#
# Usage:
#   ./track_label_prs.sh              # update LabelPRs/
#   ./track_label_prs.sh --verbose    # log added/updated/removed files to stderr
#   ./track_label_prs.sh --dry-run    # report what would change, write nothing

set -u

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
export LANG="en_US.UTF-8"

OWNER="Installomator"
REPO="Installomator"
LABELS_PREFIX="fragments/labels/"
PAGE_SIZE=25

SCRIPT_DIR="${0:A:h}"
PRS_DIR="$SCRIPT_DIR/LabelPRs"
CSV_FILE="$SCRIPT_DIR/label_prs.csv"

verbose=0
dry_run=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose) verbose=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--verbose] [--dry-run]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

log() { [[ $verbose -eq 1 ]] && echo "$@" >&2; return 0 }

for cmd in gh jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd is required but not found in PATH" >&2
        exit 1
    fi
done

tmpDir=$(mktemp -d)
trap 'rm -rf "$tmpDir"' EXIT

# Retries a gh call a few times so one transient API error doesn't wipe out
# the snapshot. Output goes to stdout only on success.
gh_retry() {
    local attempt out
    for attempt in 1 2 3; do
        if out=$(gh "$@" 2>"$tmpDir/gh_err"); then
            print -r -- "$out"
            return 0
        fi
        log "gh call failed (attempt $attempt): $(head -c 300 "$tmpDir/gh_err")"
        sleep $((attempt * 5))
    done
    cat "$tmpDir/gh_err" >&2
    return 1
}

QUERY='
query($owner: String!, $name: String!, $pageSize: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: $pageSize, after: $cursor, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        title
        url
        isDraft
        createdAt
        updatedAt
        reviewDecision
        mergeable
        author { login url }
        baseRefName
        headRefName
        headRepository { nameWithOwner }
        labels(first: 20) { nodes { name } }
        reviewRequests(first: 20) {
          nodes { requestedReviewer { ... on User { login } ... on Team { name } ... on Bot { login } } }
        }
        latestOpinionatedReviews(first: 50) {
          nodes { state submittedAt author { login } }
        }
        comments { totalCount }
        commits(last: 1) {
          totalCount
          nodes { commit { oid statusCheckRollup { state } } }
        }
        files(first: 100) {
          totalCount
          pageInfo { hasNextPage }
          nodes { path changeType additions deletions }
        }
      }
    }
  }
}'

# Fetch every open PR, one page at a time.
log "Fetching open pull requests for $OWNER/$REPO..."
cursor=""
page=0
while true; do
    page=$((page + 1))
    args=(api graphql -f query="$QUERY" -F owner="$OWNER" -F name="$REPO" -F pageSize="$PAGE_SIZE")
    [[ -n "$cursor" ]] && args+=(-f cursor="$cursor")
    if ! gh_retry "${args[@]}" > "$tmpDir/page_$page.json"; then
        echo "Failed to fetch open pull requests (page $page), aborting without changes" >&2
        exit 1
    fi
    if ! jq -e '.data.repository.pullRequests' "$tmpDir/page_$page.json" >/dev/null 2>&1; then
        echo "Unexpected GraphQL response (page $page), aborting without changes:" >&2
        head -c 500 "$tmpDir/page_$page.json" >&2
        exit 1
    fi
    [[ "$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' "$tmpDir/page_$page.json")" == "true" ]] || break
    cursor=$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' "$tmpDir/page_$page.json")
done

jq -s '[.[].data.repository.pullRequests.nodes[]]' "$tmpDir"/page_*.json(n) > "$tmpDir/prs.json"
prCount=$(jq 'length' "$tmpDir/prs.json")
log "Fetched $prCount open pull requests."

# GraphQL caps a PR's file list at 100 per page; for the rare larger PR,
# replace its file list with the full one from REST (normalized to the
# GraphQL changeType spelling).
for number in $(jq -r '.[] | select(.files.pageInfo.hasNextPage) | .number' "$tmpDir/prs.json"); do
    log "PR #$number has more than 100 files, fetching full file list..."
    if ! gh_retry api --paginate "repos/$OWNER/$REPO/pulls/$number/files?per_page=100" > "$tmpDir/files_$number.json"; then
        echo "Failed to fetch file list for PR #$number, aborting without changes" >&2
        exit 1
    fi
    jq -s 'add | map({
            path: .filename,
            changeType: (if .status == "removed" then "DELETED" else (.status | ascii_upcase) end),
            additions,
            deletions
        })' "$tmpDir/files_$number.json" > "$tmpDir/files_$number.norm.json"
    jq --argjson n "$number" --slurpfile f "$tmpDir/files_$number.norm.json" \
        'map(if .number == $n then .files.nodes = $f[0] else . end)' \
        "$tmpDir/prs.json" > "$tmpDir/prs.tmp" && mv "$tmpDir/prs.tmp" "$tmpDir/prs.json"
done

# Build one document per label: { label: { label, labelFile, pullRequests: [...] } }.
# No "fetched at" timestamp is recorded, so a file only changes (and gets
# committed) when something about its PRs actually changed.
jq --arg prefix "$LABELS_PREFIX" '
    def labelFiles: [.files.nodes[]
        | select((.path | startswith($prefix)) and (.path | endswith(".sh"))
                 and ((.path | ltrimstr($prefix)) | contains("/") | not))];
    def labelName: .path | ltrimstr($prefix) | rtrimstr(".sh");

    [ .[] | . as $pr | labelFiles as $lf | $lf[] | {
        label: labelName,
        labelFile: .path,
        pr: {
            number: $pr.number,
            title: $pr.title,
            url: $pr.url,
            author: (if $pr.author then {login: $pr.author.login, url: $pr.author.url} else {login: "ghost", url: null} end),
            isDraft: $pr.isDraft,
            createdAt: $pr.createdAt,
            updatedAt: $pr.updatedAt,
            baseBranch: $pr.baseRefName,
            headBranch: $pr.headRefName,
            headRepository: ($pr.headRepository.nameWithOwner // null),
            prLabels: [$pr.labels.nodes[].name],
            reviewDecision: $pr.reviewDecision,
            reviews: [$pr.latestOpinionatedReviews.nodes[]
                | {reviewer: (.author.login // "ghost"), state, submittedAt}],
            requestedReviewers: [$pr.reviewRequests.nodes[].requestedReviewer
                | select(. != null) | (.login // .name)],
            mergeable: $pr.mergeable,
            checksState: ($pr.commits.nodes[0].commit.statusCheckRollup.state // null),
            headCommit: ($pr.commits.nodes[0].commit.oid // null),
            commitCount: $pr.commits.totalCount,
            commentCount: $pr.comments.totalCount,
            changedFileCount: $pr.files.totalCount,
            labelChange: {changeType, additions, deletions},
            labelsInPR: [$lf[] | labelName]
        }
    } ]
    | group_by(.label)
    | map({key: .[0].label, value: {
        label: .[0].label,
        labelFile: .[0].labelFile,
        pullRequests: (map(.pr) | sort_by(.number))
    }})
    | from_entries
' "$tmpDir/prs.json" > "$tmpDir/by_label.json"

labelCount=$(jq 'length' "$tmpDir/by_label.json")

[[ $dry_run -eq 0 ]] && mkdir -p "$PRS_DIR"
mkdir -p "$tmpDir/out"

added=0
updated=0
removed=0

for label in ${(f)"$(jq -r 'keys[]' "$tmpDir/by_label.json")"}; do
    out="$tmpDir/out/$label.json"
    dest="$PRS_DIR/$label.json"
    # GitHub computes mergeability lazily and reports UNKNOWN the first time
    # a PR is queried after its base branch moves. Keep the last known value
    # instead, so the file doesn't flap between runs.
    if [[ -f "$dest" ]]; then
        jq --arg l "$label" --slurpfile prev "$dest" '
            ($prev[0].pullRequests | map({key: (.number | tostring), value: .mergeable}) | from_entries) as $known
            | .[$l]
            | .pullRequests |= map(
                if .mergeable == "UNKNOWN" and ($known[.number | tostring] // "UNKNOWN") != "UNKNOWN"
                then .mergeable = $known[.number | tostring] else . end)
        ' "$tmpDir/by_label.json" > "$out"
    else
        jq --arg l "$label" '.[$l]' "$tmpDir/by_label.json" > "$out"
    fi
    if [[ ! -f "$dest" ]]; then
        log "new: $label.json"
        added=$((added + 1))
        [[ $dry_run -eq 0 ]] && cp "$out" "$dest"
    elif ! cmp -s "$out" "$dest"; then
        log "updated: $label.json"
        updated=$((updated + 1))
        [[ $dry_run -eq 0 ]] && cp "$out" "$dest"
    fi
done

for f in "$PRS_DIR"/*.json(N); do
    name="${f:t}"
    if [[ ! -f "$tmpDir/out/$name" ]]; then
        log "removed: $name (no open PR touches it)"
        removed=$((removed + 1))
        [[ $dry_run -eq 0 ]] && rm -f "$f"
    fi
done

# label_prs.csv: one row per (label, PR) pair, built from the same documents
# just written, so it matches LabelPRs/ exactly. A PR touching several labels
# gets one row per label.
{
    echo '"label","prNumber","title","author","isDraft","reviewDecision","reviewers","requestedReviewers","mergeable","checksState","changeType","labelsInPR","createdAt","updatedAt","url"'
    for f in "$tmpDir"/out/*.json(N); do
        jq -r '.label as $label | .pullRequests[] | [
            $label,
            .number,
            .title,
            .author.login,
            .isDraft,
            .reviewDecision,
            (.reviews | map("\(.reviewer):\(.state)") | join(" ")),
            (.requestedReviewers | join(" ")),
            .mergeable,
            .checksState,
            .labelChange.changeType,
            (.labelsInPR | join(" ")),
            .createdAt,
            .updatedAt,
            .url
        ] | @csv' "$f"
    done
} > "$tmpDir/label_prs.csv"

csvChanged=0
if [[ ! -f "$CSV_FILE" ]] || ! cmp -s "$tmpDir/label_prs.csv" "$CSV_FILE"; then
    csvChanged=1
    log "updated: ${CSV_FILE:t}"
    [[ $dry_run -eq 0 ]] && cp "$tmpDir/label_prs.csv" "$CSV_FILE"
fi

echo "Label PR tracking complete: $prCount open PRs, $labelCount labels with open PRs, $added added, $updated updated, $removed removed, CSV $([[ $csvChanged -eq 1 ]] && echo updated || echo unchanged)."
exit 0

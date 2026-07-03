#!/bin/zsh
#
# Syncs Labels/ with the upstream Installomator fragments/labels directory
# (https://github.com/Installomator/Installomator/tree/main/fragments/labels)
# via a shallow sparse-checkout clone. Adds new labels, updates changed ones,
# and removes local labels that no longer exist upstream.
#
# Note: this deliberately does NOT use the GitHub contents/trees API to list
# the upstream directory - the contents API silently truncates directory
# listings at 1000 entries, and Installomator has 1000+ label files, so an
# API-based listing would silently miss some labels with no error.
#
# Usage:
#   ./sync_labels.sh              # sync Labels/ with upstream
#   ./sync_labels.sh --verbose    # log added/updated/removed labels to stderr
#   ./sync_labels.sh --dry-run    # report what would change, write nothing

set -u

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
export LANG="en_US.UTF-8"

REPO_URL="https://github.com/Installomator/Installomator.git"
BRANCH="main"
UPSTREAM_SUBDIR="fragments/labels"

SCRIPT_DIR="${0:A:h}"
LABELS_DIR="$SCRIPT_DIR/Labels"

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

if ! command -v git >/dev/null 2>&1; then
    echo "git is required but not found in PATH" >&2
    exit 1
fi

tmpDir=$(mktemp -d)
trap 'rm -rf "$tmpDir"' EXIT

log "Cloning $REPO_URL ($BRANCH, sparse: $UPSTREAM_SUBDIR)..."
if ! git clone --quiet --depth 1 --branch "$BRANCH" --filter=blob:none --sparse "$REPO_URL" "$tmpDir/repo" 2>/dev/null; then
    echo "Failed to clone $REPO_URL" >&2
    exit 1
fi

if ! git -C "$tmpDir/repo" sparse-checkout set "$UPSTREAM_SUBDIR" >/dev/null 2>&1; then
    echo "Failed to sparse-checkout $UPSTREAM_SUBDIR" >&2
    exit 1
fi

upstreamDir="$tmpDir/repo/$UPSTREAM_SUBDIR"
if [[ ! -d "$upstreamDir" ]]; then
    echo "Upstream labels directory not found after clone: $UPSTREAM_SUBDIR" >&2
    exit 1
fi

upstreamCount=$(ls -1 "$upstreamDir"/*.sh(N) 2>/dev/null | wc -l | tr -d ' ')
if [[ "$upstreamCount" -eq 0 ]]; then
    echo "Upstream labels directory is empty, aborting sync as a safety check" >&2
    exit 1
fi

mkdir -p "$LABELS_DIR"

added=0
updated=0
removed=0

for f in "$upstreamDir"/*.sh(N); do
    name="${f:t}"
    dest="$LABELS_DIR/$name"
    if [[ ! -f "$dest" ]]; then
        log "new label: $name"
        added=$((added + 1))
        [[ $dry_run -eq 0 ]] && cp "$f" "$dest"
    elif ! cmp -s "$f" "$dest"; then
        log "updated label: $name"
        updated=$((updated + 1))
        [[ $dry_run -eq 0 ]] && cp "$f" "$dest"
    fi
done

for f in "$LABELS_DIR"/*.sh(N); do
    name="${f:t}"
    if [[ ! -f "$upstreamDir/$name" ]]; then
        log "removed label: $name (no longer upstream)"
        removed=$((removed + 1))
        [[ $dry_run -eq 0 ]] && rm -f "$f"
    fi
done

echo "Sync complete: $upstreamCount upstream labels, $added added, $updated updated, $removed removed."
exit 0

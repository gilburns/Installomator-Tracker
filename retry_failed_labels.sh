#!/bin/zsh
#
# Retries every label currently listed in failed_labels.json, one at a time,
# via `update_tracked_labels.sh --label <name>`. That flag already knows how
# to bypass the skip check and correctly update (or clear) just that one
# label's entry without disturbing the shared hash/retry-timer state used by
# full runs - so this script is just the iteration over the failed set.
#
# Usage:
#   ./retry_failed_labels.sh              # retry every currently-failed label
#   ./retry_failed_labels.sh --verbose    # pass --verbose through to each retry
#   ./retry_failed_labels.sh --dry-run    # preview only, write nothing

set -u

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
export LANG="en_US.UTF-8"

SCRIPT_DIR="${0:A:h}"
FAILED_LABELS_FILE="$SCRIPT_DIR/failed_labels.json"
UPDATE_SCRIPT="$SCRIPT_DIR/update_tracked_labels.sh"

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

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not found in PATH" >&2
    exit 1
fi

if [[ ! -f "$FAILED_LABELS_FILE" ]]; then
    echo "No $FAILED_LABELS_FILE found - nothing to retry."
    exit 0
fi

typeset -a failedLabels
failedLabels=("${(@f)$(jq -r '.failed // {} | keys[]' "$FAILED_LABELS_FILE")}")

if [[ ${#failedLabels[@]} -eq 0 || -z "${failedLabels[1]:-}" ]]; then
    echo "No failed labels to retry."
    exit 0
fi

echo "Retrying ${#failedLabels[@]} previously-failed label(s)..."

typeset -a extraArgs
[[ $verbose -eq 1 ]] && extraArgs+=(--verbose)
[[ $dry_run -eq 1 ]] && extraArgs+=(--dry-run)

fixedCount=0
stillFailedCount=0
noVersionCount=0
typeset -a noVersionLabels

for label in "${failedLabels[@]}"; do
    # Same pre-check as update_tracked_labels.sh: a label that never sets
    # appNewVersion can't start resolving on a retry, so don't spend a run
    # on it. Its failed_labels.json reason is corrected after the loop.
    labelFile="$SCRIPT_DIR/Labels/$label.sh"
    if [[ -f "$labelFile" ]] && ! grep -vE '^[[:space:]]*#' "$labelFile" | grep -Eq 'appNewVersion|versionFromGit'; then
        echo "--- skipping $label (label does not set appNewVersion) ---"
        noVersionLabels+=("$label")
        noVersionCount=$((noVersionCount + 1))
        continue
    fi

    echo "--- retrying $label ---"
    tmpOut=$(mktemp)
    "$UPDATE_SCRIPT" --label "$label" "${extraArgs[@]}" 2>&1 | tee "$tmpOut"

    # Read the failure count back out of update_tracked_labels.sh's own
    # summary line rather than re-checking failed_labels.json afterward -
    # that file is never written in --dry-run mode, so re-reading it would
    # misreport everything as "still failing" regardless of the real result.
    failedThisLabel=$(grep -oE '[0-9]+ failed' "$tmpOut" | grep -oE '^[0-9]+')
    rm -f "$tmpOut"

    if [[ "$failedThisLabel" == "0" ]]; then
        fixedCount=$((fixedCount + 1))
    else
        stillFailedCount=$((stillFailedCount + 1))
    fi
done

# Record the specific reason for the skipped labels in one write, keeping
# firstSeen. Done after the loop since each retry above rewrites the file.
if [[ $dry_run -eq 0 && ${#noVersionLabels[@]} -gt 0 ]]; then
    tmpStateFile=$(mktemp)
    if jq -S --arg reason "label does not set appNewVersion" --arg now "$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '($ARGS.positional) as $labels
        | reduce $labels[] as $l (.;
            if .failed[$l].reason == $reason then .
            else .failed[$l] = {reason: $reason, firstSeen: (.failed[$l].firstSeen // $now), lastSeen: $now} end)' \
        "$FAILED_LABELS_FILE" --args "${noVersionLabels[@]}" > "$tmpStateFile"; then
        if cmp -s "$tmpStateFile" "$FAILED_LABELS_FILE"; then
            rm -f "$tmpStateFile"
        else
            mv "$tmpStateFile" "$FAILED_LABELS_FILE"
        fi
    else
        echo "Failed to update reasons in $FAILED_LABELS_FILE" >&2
        rm -f "$tmpStateFile"
    fi
fi

echo ""
echo "Done. ${#failedLabels[@]} failed labels: $fixedCount now resolving, $stillFailedCount still failing, $noVersionCount skipped (label does not set appNewVersion)."

#!/bin/zsh
#
# Runs process_label.sh against every label in Labels/, and for each one
# appends a new entry to TrackedLabelDetails/<label>.json if the resolved
# appNewVersion isn't already recorded there. Safe to run repeatedly - already
#-seen versions are left alone.
#
# Labels that fail to resolve (no appNewVersion/downloadURL, or a hard
# timeout) are recorded in failed_labels.json and skipped on subsequent full
# runs, since most such failures are structural (the label script itself
# never sets appNewVersion) and will fail identically every run until the
# label is fixed upstream. That cache is invalidated - and everything
# retried - whenever the content of Labels/ changes (a content hash, not the
# upstream repo's commit SHA, so unrelated upstream commits don't trigger a
# reset), or after 7 days regardless, as a safety valve against a label
# that's stuck blacklisted from a one-off transient failure.
#
# Usage:
#   ./update_tracked_labels.sh                 # process every label
#   ./update_tracked_labels.sh --label firefoxpkg   # process a single label,
#                                                     # bypassing the failed-label skip
#   ./update_tracked_labels.sh --verbose        # log per-label progress to stderr
#   ./update_tracked_labels.sh --dry-run        # report what would change, write nothing

set -u

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
export LANG="en_US.UTF-8"

SCRIPT_DIR="${0:A:h}"
LABELS_DIR="$SCRIPT_DIR/Labels"
TRACKED_DIR="$SCRIPT_DIR/TrackedLabelDetails"
PROCESS_LABEL="$SCRIPT_DIR/process_label.sh"
FAILED_LABELS_FILE="$SCRIPT_DIR/failed_labels.json"
TIMEOUT_SECS=60
FORCE_RETRY_INTERVAL_SECS=$((7 * 24 * 60 * 60))

verbose=0
dry_run=0
only_label=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose) verbose=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --label) only_label="${2:-}"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--label <name>] [--verbose] [--dry-run]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

log() { [[ $verbose -eq 1 ]] && echo "$@" >&2; return 0 }

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not found in PATH" >&2
    exit 1
fi

if [[ ! -d "$LABELS_DIR" ]]; then
    echo "Labels directory not found: $LABELS_DIR" >&2
    exit 1
fi

mkdir -p "$TRACKED_DIR"

typeset -a labelFiles
if [[ -n "$only_label" ]]; then
    labelFiles=("$LABELS_DIR/$only_label.sh")
    if [[ ! -f "${labelFiles[1]}" ]]; then
        echo "Label file not found: ${labelFiles[1]}" >&2
        exit 1
    fi
else
    labelFiles=("$LABELS_DIR"/*.sh(N))
fi

if [[ ${#labelFiles[@]} -eq 0 ]]; then
    echo "No label files found in $LABELS_DIR" >&2
    exit 1
fi

# Runs process_label.sh for a single label with a hard timeout, since a hung
# network call in a label script would otherwise block the whole batch (and
# a scheduled CI run) indefinitely. Pass "x86_64" as the third argument to
# resolve the label under Rosetta instead of natively (see isDualArchLabel
# below).
#
# Implemented with perl's alarm()+exec instead of a shell background job +
# watchdog process: the background+`wait`+`kill` approach depends on zsh job
# control, which behaves inconsistently across invocation contexts (e.g. it
# reliably hangs for the full timeout when this script itself is invoked
# from inside a subshell/command-substitution, such as a calling loop doing
# out=$(./update_tracked_labels.sh ...)). alarm()+exec runs the target
# command in the foreground with no job-control dependency at all.
runLabelWithTimeout() {
    local labelFile="$1"
    local outFile="$2"
    local archFlag="${3:-}"

    if [[ -n "$archFlag" ]]; then
        perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_SECS" /usr/bin/arch "-$archFlag" "$PROCESS_LABEL" "$labelFile" < /dev/null > "$outFile" 2>/dev/null
    else
        perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_SECS" "$PROCESS_LABEL" "$labelFile" < /dev/null > "$outFile" 2>/dev/null
    fi

    return $?
}

# A label counts as "dual arch" if it calls $(arch) or $(/usr/bin/arch) at
# all, regardless of whether it branches with an explicit i386/x86_64 case
# or just an else - both forms mean the resolved downloadURL can differ
# between architectures. We don't try to prove upfront that it *will*
# differ; we just resolve both and only keep the second one if it does.
isDualArchLabel() {
    grep -Eq '\$\((/usr/bin/)?arch\)' "$1"
}

# Content fingerprint of the current Labels/ set: every filename+content pair,
# sorted by filename, hashed together into one digest. Changes if and only if
# a label was added, removed, or its content changed - deliberately not the
# upstream Installomator repo's HEAD SHA, which changes on any commit
# (docs, CI, the main script) whether or not fragments/labels was touched.
computeLabelsHash() {
    find "$LABELS_DIR" -type f -name "*.sh" -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256 \
        | awk '{print $1}'
}

# --label targets one label for ad hoc testing/debugging - always run it
# regardless of failed-label history, and never let it perturb the shared
# hash/retry-timer state (only a full run legitimately re-validates the
# whole set).
bypassBlacklist=0
isFullRun=1
if [[ -n "$only_label" ]]; then
    bypassBlacklist=1
    isFullRun=0
fi

if [[ -f "$FAILED_LABELS_FILE" ]]; then
    failedState=$(<"$FAILED_LABELS_FILE")
else
    failedState='{"labelsHash":"","lastFullRetry":"1970-01-01T00:00:00Z","failed":{}}'
fi

currentLabelsHash=$(computeLabelsHash)
storedHash=$(echo "$failedState" | jq -r '.labelsHash // ""')
lastFullRetry=$(echo "$failedState" | jq -r '.lastFullRetry // "1970-01-01T00:00:00Z"')

forceFullRetry=0
if [[ $isFullRun -eq 1 ]]; then
    if [[ "$storedHash" != "$currentLabelsHash" ]]; then
        forceFullRetry=1
        log "Labels set changed since last run, clearing failed-label cache"
    else
        nowEpoch=$(date -u +%s)
        lastRetryEpoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$lastFullRetry" +%s 2>/dev/null || echo 0)
        if [[ $((nowEpoch - lastRetryEpoch)) -ge $FORCE_RETRY_INTERVAL_SECS ]]; then
            forceFullRetry=1
            log "Weekly safety-valve retry triggered (last full retry was $lastFullRetry)"
        fi
    fi
fi

if [[ $forceFullRetry -eq 1 ]]; then
    skipSet='{}'
    newFailedMap='{}'
else
    skipSet=$(echo "$failedState" | jq -c '.failed // {}')
    newFailedMap="$skipSet"
fi

newCount=0
replacedCount=0
unchangedCount=0
failCount=0
skippedCount=0
totalCount=${#labelFiles[@]}

for labelFile in "${labelFiles[@]}"; do
    label="${labelFile:t:r}"

    if [[ $bypassBlacklist -eq 0 ]] && echo "$skipSet" | jq -e --arg l "$label" 'has($l)' >/dev/null 2>&1; then
        log "[$label] skipping (previously failed, no upstream changes)"
        skippedCount=$((skippedCount + 1))
        continue
    fi

    log "[$label] processing..."

    outFile=$(mktemp)
    runLabelWithTimeout "$labelFile" "$outFile"
    exitStatus=$?
    jsonOutput=$(<"$outFile")
    rm -f "$outFile"

    if [[ $exitStatus -ne 0 || -z "$jsonOutput" ]]; then
        echo "[$label] FAILED to resolve (exit $exitStatus)" >&2
        newFailedMap=$(echo "$newFailedMap" | jq --arg l "$label" --arg reason "resolve failed (exit $exitStatus)" --arg now "$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")" '
            .[$l] = {reason: $reason, firstSeen: (.[$l].firstSeen // $now), lastSeen: $now}
        ')
        failCount=$((failCount + 1))
        continue
    fi

    if ! echo "$jsonOutput" | jq empty >/dev/null 2>&1; then
        echo "[$label] FAILED: invalid JSON output" >&2
        newFailedMap=$(echo "$newFailedMap" | jq --arg l "$label" --arg reason "invalid JSON output" --arg now "$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")" '
            .[$l] = {reason: $reason, firstSeen: (.[$l].firstSeen // $now), lastSeen: $now}
        ')
        failCount=$((failCount + 1))
        continue
    fi

    appNewVersion=$(echo "$jsonOutput" | jq -r '.appNewVersion // empty')
    downloadURL=$(echo "$jsonOutput" | jq -r '.downloadURL // empty')

    if [[ -z "$appNewVersion" || -z "$downloadURL" ]]; then
        echo "[$label] FAILED: missing appNewVersion or downloadURL" >&2
        newFailedMap=$(echo "$newFailedMap" | jq --arg l "$label" --arg reason "missing appNewVersion or downloadURL" --arg now "$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")" '
            .[$l] = {reason: $reason, firstSeen: (.[$l].firstSeen // $now), lastSeen: $now}
        ')
        failCount=$((failCount + 1))
        continue
    fi

    # Resolved successfully - make sure it's not lingering in the failed map
    # (e.g. a --label run retrying something the bulk run had blacklisted).
    newFailedMap=$(echo "$newFailedMap" | jq --arg l "$label" 'del(.[$l])')

    # This run resolved the label natively (arm64 on the Apple Silicon hosts
    # this is expected to run on). If the label also branches on arch, do a
    # second pass under Rosetta to capture the Intel downloadURL alongside it.
    if isDualArchLabel "$labelFile"; then
        log "[$label] dual-arch label, resolving x86_64/i386 variant..."
        i386OutFile=$(mktemp)
        runLabelWithTimeout "$labelFile" "$i386OutFile" x86_64
        i386ExitStatus=$?
        i386JsonOutput=$(<"$i386OutFile")
        rm -f "$i386OutFile"

        if [[ $i386ExitStatus -eq 0 && -n "$i386JsonOutput" ]] && echo "$i386JsonOutput" | jq empty >/dev/null 2>&1; then
            downloadURLi386=$(echo "$i386JsonOutput" | jq -r '.downloadURL // empty')
            if [[ -n "$downloadURLi386" && "$downloadURLi386" != "$downloadURL" ]]; then
                jsonOutput=$(echo "$jsonOutput" | jq --arg u "$downloadURLi386" '. + {downloadURLi386: $u}')
                log "[$label] captured downloadURLi386: $downloadURLi386"
            else
                log "[$label] x86_64 pass produced no distinct downloadURL, skipping downloadURLi386"
            fi
        else
            echo "[$label] WARN: failed to resolve x86_64/i386 variant (exit $i386ExitStatus)" >&2
        fi
    fi

    # Read current tracked content without touching disk, so --dry-run never
    # creates a file (not even an empty [] placeholder) for a label that
    # doesn't have one yet.
    trackedFile="$TRACKED_DIR/$label.json"
    if [[ -f "$trackedFile" ]]; then
        currentTracked=$(<"$trackedFile")
    else
        currentTracked="[]"
    fi

    alreadyTracked=$(echo "$currentTracked" | jq --arg v "$appNewVersion" 'any(.[]; .appNewVersion == $v)')

    tmpFile=$(mktemp)
    if [[ "$alreadyTracked" == "true" ]]; then
        log "[$label] version $appNewVersion already tracked"
        unchangedCount=$((unchangedCount + 1))
        # Re-verify sort order even when nothing new was found, so a file
        # that somehow got out of order (manual edit, backfill, merge) heals
        # on the next run instead of only ever being sorted on new writes.
        # Also back-fill downloadURLi386 onto the matching entry if this run
        # resolved one and it wasn't captured previously - an i386 URL is
        # only ever discoverable while that version is still current, so
        # this is the one field worth patching onto an existing record.
        jqStatus=0
        echo "$currentTracked" | jq -S --argjson entry "$jsonOutput" --arg v "$appNewVersion" '
            map(
                if .appNewVersion == $v
                    and ($entry | has("downloadURLi386"))
                    and ((.downloadURLi386 // "") == "")
                then . + {downloadURLi386: $entry.downloadURLi386}
                else .
                end
            ) | sort_by(.timeStamp)
        ' > "$tmpFile" || jqStatus=$?
    else
        # Some labels (e.g. 1password8) never redirect to a version-specific
        # download URL - they just always point at "latest". For those, every
        # tracked entry would carry an identical downloadURL that's already
        # stale the moment a newer version ships, so accumulating history is
        # pointless. Detect that case by comparing against the most recently
        # tracked entry: if its downloadURL is identical to what we just
        # resolved, replace it in place instead of appending. A label that
        # does produce version-pinned URLs will never match here, so this
        # only ever affects the static-URL pattern.
        lastDownloadURL=$(echo "$currentTracked" | jq -r 'if length > 0 then (sort_by(.timeStamp) | last | .downloadURL) else empty end')

        if [[ -n "$lastDownloadURL" && "$lastDownloadURL" == "$downloadURL" ]]; then
            echo "[$label] new version: $appNewVersion (static downloadURL unchanged, replacing previous entry)"
            replacedCount=$((replacedCount + 1))
            jqStatus=0
            echo "$currentTracked" | jq -S --argjson entry "$jsonOutput" '
                (sort_by(.timeStamp)) as $sorted
                | ($sorted[:-1] + [$entry]) | sort_by(.timeStamp)
            ' > "$tmpFile" || jqStatus=$?
        else
            echo "[$label] new version: $appNewVersion"
            newCount=$((newCount + 1))
            jqStatus=0
            echo "$currentTracked" | jq -S --argjson entry "$jsonOutput" '. + [$entry] | sort_by(.timeStamp)' > "$tmpFile" || jqStatus=$?
        fi
    fi

    if [[ $jqStatus -ne 0 ]]; then
        echo "[$label] FAILED to update $trackedFile" >&2
        rm -f "$tmpFile"
        failCount=$((failCount + 1))
        continue
    fi

    if [[ $dry_run -eq 1 ]] || cmp -s "$tmpFile" "$trackedFile" 2>/dev/null; then
        rm -f "$tmpFile"
    else
        mv "$tmpFile" "$trackedFile"
    fi
done

echo ""
echo "Done. $totalCount labels processed: $newCount new, $replacedCount replaced (static URL), $unchangedCount unchanged, $failCount failed, $skippedCount skipped (known-broken)."

if [[ $dry_run -eq 0 ]]; then
    if [[ $isFullRun -eq 1 ]]; then
        newHash="$currentLabelsHash"
        newLastFullRetry="$lastFullRetry"
        [[ $forceFullRetry -eq 1 ]] && newLastFullRetry=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")
    else
        # A --label run only checked one label - it must not overwrite the
        # hash/retry-timer fields, which only a full run can legitimately
        # attest to (they mean "the whole set was checked as of here").
        newHash="$storedHash"
        newLastFullRetry="$lastFullRetry"
    fi

    newState=$(jq -n -S --arg hash "$newHash" --arg lastFullRetry "$newLastFullRetry" --argjson failed "$newFailedMap" \
        '{labelsHash: $hash, lastFullRetry: $lastFullRetry, failed: $failed}')

    tmpStateFile=$(mktemp)
    echo "$newState" > "$tmpStateFile"
    if [[ -f "$FAILED_LABELS_FILE" ]] && cmp -s "$tmpStateFile" "$FAILED_LABELS_FILE"; then
        rm -f "$tmpStateFile"
    else
        mv "$tmpStateFile" "$FAILED_LABELS_FILE"
    fi
fi

if [[ $failCount -eq $totalCount && $totalCount -gt 0 ]]; then
    exit 1
fi

exit 0

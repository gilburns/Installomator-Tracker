# Installomator Tracker

Automated, historical version/download-URL tracking for every [Installomator](https://github.com/Installomator/Installomator) label.

[Installomator](https://github.com/Installomator/Installomator) is a shell-based tool that resolves the current download URL and version for ~1,163 macOS applications, then installs whichever one you tell it to. It always resolves to *whatever is current right now* - it has no memory of what a given version's download URL used to be.

This repo runs that resolution logic for every label, twice a day, and keeps a running history: for each label, every version ever seen, with the download URL and metadata that were live for that version at the time it was discovered. The result is a queryable archive you can use to answer "what was the download URL for version X of label Y?" - something Installomator itself was never designed to answer.

## How it works

A scheduled GitHub Actions workflow ([.github/workflows/track-labels.yml](.github/workflows/track-labels.yml)) runs on a `macos-latest` runner twice daily (06:00 and 18:00 UTC, plus on-demand via `workflow_dispatch`) and does three things in order, committing after each:

1. **Sync labels from upstream** ([sync_labels.sh](sync_labels.sh)) - pulls the current [`fragments/labels`](https://github.com/Installomator/Installomator/tree/main/fragments/labels) directory from Installomator's `main` branch via a shallow sparse-checkout clone, and mirrors it into [`Labels/`](Labels/): new labels are added, changed labels are updated, and labels removed upstream are deleted locally.
2. **Run the label tracker** ([update_tracked_labels.sh](update_tracked_labels.sh)) - resolves every label in `Labels/` (via [process_label.sh](process_label.sh), a trimmed-down harness that evaluates a single label fragment the same way Installomator itself does) and records any newly-discovered version into [`TrackedLabelDetails/<label>.json`](TrackedLabelDetails/).
3. Commits whatever changed in `Labels/` and `TrackedLabelDetails/` back to this repo.

### Why a version only gets recorded once

Each label is resolved to a version number and download URL, same as running Installomator directly. If that version isn't already in `TrackedLabelDetails/<label>.json`, it's appended (or, for the handful of labels whose download URL never changes and always points at "latest" - see below - the previous entry is replaced instead). Already-seen versions are left alone. Over time this builds a full version history per label instead of just "whatever is current today."

### Static-URL labels (no history to accumulate)

A few labels (e.g. `1password8`) never redirect to a version-pinned URL - they just always point at "latest," so every entry would carry an identical, already-stale-by-tomorrow download URL. For those, `update_tracked_labels.sh` detects the repeat and replaces the previous entry in place rather than accumulating meaningless duplicates. That label's file will only ever have one entry, updated as new versions ship.

### Dual-architecture labels

Some labels branch on `$(arch)` to serve different Intel vs. Apple Silicon download URLs. Since these runs happen on Apple Silicon GitHub runners, the natural resolution only ever captures the arm64 URL. For any label that branches on architecture, the tracker does a second pass under Rosetta (`arch -x86_64`) and, if it resolves to a different URL, records it alongside the primary one as `downloadURLi386`.

### Skipping known-broken labels

Some labels can't be resolved through this lightweight method at all - about ~250 of the ~1,163, mostly because the label script itself never sets `appNewVersion` (it relies on Installomator's full install flow inspecting the downloaded installer after the fact, which this project doesn't do). Since those fail identically on every run, [`failed_labels.json`](failed_labels.json) records them and they're skipped on subsequent runs - no point re-paying the network cost for a label that hasn't changed and is going to fail the same way again. That cache resets automatically whenever the actual content of `Labels/` changes (so a label fixed upstream gets retried), with a 7-day fallback retry regardless, in case something was blacklisted from a one-off transient failure rather than a real problem.

## Repo layout

| Path | What it is |
|---|---|
| `Labels/` | Mirror of Installomator's `fragments/labels`, kept in sync automatically. Not hand-edited. |
| `TrackedLabelDetails/<label>.json` | Version history for one label - a JSON array of entries, oldest to newest. |
| `failed_labels.json` | Labels that currently can't be resolved, and why, so they're skipped instead of retried every run. |
| `process_label.sh` | Resolves a single label file to one JSON result (version, download URL, metadata). |
| `sync_labels.sh` | Mirrors `Labels/` from upstream Installomator. |
| `update_tracked_labels.sh` | Runs `process_label.sh` over every label and updates `TrackedLabelDetails/`. |
| `.github/workflows/track-labels.yml` | The scheduled automation tying it all together. |

## Tracked entry format

Each element of `TrackedLabelDetails/<label>.json` looks like this (from `gimp.json`, a dual-architecture label):

```json
{
  "appName": "",
  "appNewVersion": "3.2.4",
  "blockingProcesses": [],
  "downloadURL": "https://southfront.mm.fcix.net/gimp/gimp/v3.2/macos/gimp-3.2.4-arm64.dmg",
  "downloadURLi386": "https://southfront.mm.fcix.net/gimp/gimp/v3.2/macos/gimp-3.2.4-x86_64.dmg",
  "expectedTeamID": "T25BQ8HSJF",
  "label": "gimp",
  "name": "GIMP",
  "timeStamp": "2026-07-03T15:46:49Z",
  "type": "dmg"
}
```

`downloadURLi386` is only present for labels where the Intel download URL genuinely differs from the Apple Silicon one. `timeStamp` is when this tracker discovered the version - not the vendor's release date, which isn't reliably available across every label.

## Running it locally

```sh
./sync_labels.sh --verbose                    # mirror Labels/ from upstream Installomator
./update_tracked_labels.sh --verbose          # resolve every label, update TrackedLabelDetails/
./update_tracked_labels.sh --label firefoxpkg --verbose   # just one label, bypasses failed_labels.json
./update_tracked_labels.sh --dry-run --verbose            # preview changes, write nothing
```

Both scripts require `jq` and `perl` (both ship with macOS). A full run across all labels takes roughly 30-40 minutes on first run; subsequent runs are faster once `failed_labels.json` has something to skip.

## License

MIT - see [LICENSE.md](LICENSE.md).

# Installomator Tracker

Automated, historical version/download-URL tracking for every [Installomator](https://github.com/Installomator/Installomator) label.

[Installomator](https://github.com/Installomator/Installomator) is a shell-based tool that resolves the current download URL and version for ~1,163 macOS applications, then installs whichever one you tell it to. It always resolves to *whatever is current right now* - it has no memory of what a given version's download URL used to be.

This repo runs that resolution logic for every label, twice a day, and keeps a running history: for each label, every version ever seen, with the download URL and metadata that were live for that version at the time it was discovered. The result is a queryable archive you can use to answer "what was the download URL for version X of label Y?" - something Installomator itself was never designed to answer.

## How it works

A scheduled GitHub Actions workflow ([.github/workflows/track-labels.yml](.github/workflows/track-labels.yml)) runs on a `macos-latest` runner twice daily (06:00 and 18:00 UTC, plus on-demand via `workflow_dispatch`) and does three things in order, committing after each:

1. **Sync labels from upstream** ([sync_labels.sh](sync_labels.sh)) - pulls the current [`fragments/labels`](https://github.com/Installomator/Installomator/tree/main/fragments/labels) directory from Installomator's `main` branch via a shallow sparse-checkout clone, and mirrors it into [`Labels/`](Labels/): new labels are added, changed labels are updated, and labels removed upstream are deleted locally.
2. **Run the label tracker** ([update_tracked_labels.sh](update_tracked_labels.sh)) - resolves every label in `Labels/` (via [process_label.sh](process_label.sh), a trimmed-down harness that evaluates a single label fragment the same way Installomator itself does) and records any newly-discovered version into [`TrackedLabelDetails/<label>.json`](TrackedLabelDetails/), then rewrites the [`label_status.csv`](label_status.csv) snapshot.
3. Commits whatever changed in `Labels/`, `TrackedLabelDetails/`, `failed_labels.json` and `label_status.csv` back to this repo.

### Status snapshot

[`label_status.csv`](label_status.csv) has one row per label with its `label`, `name`, `appName`, and the `appNewVersion` and `timeStamp` of its most recent tracked entry. The `status` column says `success` for labels that resolve, or gives the [`failed_labels.json`](failed_labels.json) reason for those that don't. A failing label still shows its last tracked version if it ever resolved; if it never did, `name`/`appName` come from the label file when they're set there as plain strings. It's a current snapshot, rewritten in place on every run, with no history kept (git history aside).

### Why a version only gets recorded once

Each label is resolved to a version number and download URL, same as running Installomator directly. If that version isn't already in `TrackedLabelDetails/<label>.json`, it's appended (for the handful of labels whose download URL never changes and always points at "latest" - see below - the previous entry's download URLs are also removed). Already-seen versions are left alone. Over time this builds a full version history per label instead of just "whatever is current today."

### Static-URL labels (version history only)

A few labels (e.g. `1password8`) never redirect to a version-pinned URL - they just always point at "latest," so once a newer version ships, the previous entry's download URL no longer downloads the version it's recorded against. For those, `update_tracked_labels.sh` detects the repeat, still appends the new version as its own entry, and removes `downloadURL` (and `downloadURLi386`, if present) from the previous entry. Only the newest entry carries a download URL. Older entries still record each version and when it was first seen.

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
| `label_status.csv` | Current-state snapshot of every label: latest version, timestamp, and `success` or failure reason. |
| `process_label.sh` | Resolves a single label file to one JSON result (version, download URL, metadata). |
| `sync_labels.sh` | Mirrors `Labels/` from upstream Installomator. |
| `update_tracked_labels.sh` | Runs `process_label.sh` over every label and updates `TrackedLabelDetails/`. |
| `retry_failed_labels.sh` | Retries every label currently in `failed_labels.json`, one at a time. |
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

## FAQ

### Why do some labels only have one download link, even though they list several versions?

Those are [static-URL labels](#static-url-labels-version-history-only). The label resolves to a URL that always serves "latest" (for example `https://vendor.example.com/download/latest`), not a URL tied to one version. When a new version ships, the old URL starts downloading the new version, so keeping it on the old entry would be wrong. The tracker still records every version it sees and when it first saw it, but only the newest entry keeps a `downloadURL`.

**Want full per-version download history for one of these labels?** The fix belongs upstream, not here. If the vendor publishes version-specific download URLs (a versioned path, a release/CDN listing, a GitHub release asset, etc.), rework the label in the [Installomator repo](https://github.com/Installomator/Installomator) so it resolves to that versioned URL, and submit a PR. Once it's merged, the next sync here picks up the new label, and from then on each new version is recorded with its own download URL. Versions recorded before the change keep only their version and timestamp. The tracker can't go back and find URLs it never saw.

### Why is a label missing from `TrackedLabelDetails/`, or why did it stop updating?

It's most likely listed in [`failed_labels.json`](failed_labels.json), along with the reason it failed. The most common reason is that the label never sets `appNewVersion` itself (see [Skipping known-broken labels](#skipping-known-broken-labels)). A failure can also come from the vendor's site being down or changed, or from a label that's broken upstream. As with static-URL labels, the lasting fix is to update the label in Installomator so it sets both `appNewVersion` and `downloadURL` up front. Failed labels are retried automatically when `Labels/` changes, and at least every 7 days. To retry right away, run `./retry_failed_labels.sh` (or `./update_tracked_labels.sh --label <name>` for just one).

### Why does a label fail here, even though it works when I run Installomator myself?

A handful of labels (around 5 or 6) consistently fail on the GitHub Actions runner but resolve fine when `update_tracked_labels.sh` is run on an ordinary Mac. The likely cause, though it hasn't been confirmed, is that the vendor's web server or CDN blocks or challenges traffic from cloud data-center IP ranges like the ones GitHub's runners use. The label itself is fine, and fixing it upstream won't help.

Because the scheduled workflow can't reach those vendors, these labels only get new entries when someone runs the tracker locally and commits the results:

```sh
./update_tracked_labels.sh --label <name> --verbose
git add TrackedLabelDetails/<name>.json failed_labels.json
git commit -m "Update <name> from local run"
```

Unless that's done regularly, their history will have gaps or stop updating. If you notice one of these labels falling behind, a PR with a locally generated update is welcome.

### Can I fix a label by editing it in this repo?

No. `Labels/` is an automatic mirror of upstream Installomator, and the next sync overwrites any local edits. Label changes go to the [Installomator repo](https://github.com/Installomator/Installomator). This repo picks them up within about 12 hours of the change landing on Installomator's `main` branch.

### Why doesn't a label's history go back further?

The tracker only records versions it actually sees while it's running. It started in July 2026, so nothing earlier is here. Because it checks twice a day, a version that is released and replaced between two runs can also be missed.

### Is `timeStamp` the vendor's release date?

No. It's when this tracker first saw that version, which is usually within about 12 hours of the version going live in Installomator's resolution. Vendor release dates aren't reliably available across labels.

### Will a recorded download URL still work?

Not necessarily. The tracker records the URL that was live when the version was found. It doesn't mirror the installers or re-check old URLs later. Vendors often delete or move old builds, so older links can break over time. Treat the history as a record of where a version was published, not a guaranteed download archive.

### Why is there no `downloadURLi386` for a label I know supports Intel?

`downloadURLi386` is only recorded when the label branches on architecture *and* the Intel resolution gives a different URL from the Apple Silicon one. Universal binaries, and labels that serve one URL for both architectures, only get `downloadURL`. See [Dual-architecture labels](#dual-architecture-labels).

## License

MIT - see [LICENSE.md](LICENSE.md).

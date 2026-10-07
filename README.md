# PhotoCleaner

[![CI](https://github.com/alastorid/PhotoCleaner/actions/workflows/ci.yml/badge.svg)](https://github.com/alastorid/PhotoCleaner/actions/workflows/ci.yml)

A fast, local, private way to triage a large Apple Photos library using Apple's
own Vision aesthetics score.

PhotoCleaner reads your library through **PhotoKit**, scores every still photo
with **`CalculateImageAestheticsScoresRequest`** on device, and gives you a fast
grid sorted by that score — so you can find the boring, accidental
and low-interest photos, look at them, and delete them safely through Photos.

**The AI does not decide what gets deleted.** The score is a sorting and
discovery mechanism; you make every deletion decision.

```
Apple Photos ──PhotoKit──► thumbnails + metadata ──► Vision (aesthetics) ──► SQLite cache
                                                     │
                                        localhost HTTP server ──► native window (WKWebView)
```

---

## Requirements

- **macOS 15.0 or later.** `CalculateImageAestheticsScoresRequest` was introduced
  in macOS 15. On anything older PhotoCleaner exits immediately with a clear
  message rather than substituting a different model.
- **Apple Silicon** recommended (the build targets the host architecture). The
  release DMG is Apple silicon only; `./build.sh` builds for whatever Mac it runs
  on, and `PHOTOCLEANER_ARCH=x86_64 ./build.sh` builds for Intel.
- A Swift toolchain (Xcode **or** just the Command Line Tools) to build. The app
  itself has no package manager, no dependency resolution and no third-party
  runtime. Node is needed only for the optional web-UI test suite — see
  [docs/WEB-UI-TESTS.md](docs/WEB-UI-TESTS.md).

## Install

Grab the latest `.dmg` from [Releases](https://github.com/alastorid/PhotoCleaner/releases),
open it, and drag **PhotoCleaner** onto **Applications**. That is the whole
install — the disk image contains the app and an `Applications` shortcut, and
nothing else runs.

Uninstalling is `⌫` on `/Applications/PhotoCleaner.app`, plus
[removing what it stores](#remove-everything-photocleaner-stores) if you want the
cache and logs gone too.

### "PhotoCleaner cannot be opened" or "is damaged"

Expected on first launch, once per Mac. The app is **ad-hoc signed** rather than
signed with a paid Apple Developer ID, so Gatekeeper will not vouch for it, and
anything downloaded from the internet is quarantined.

Open it once by hand and it never asks again:

1. ⌘-click (or right-click) **PhotoCleaner** in `/Applications` → **Open** →
   **Open**.
2. Or: **System Settings → Privacy & Security**, which offers **Open Anyway**
   right after the first failed launch.

The last resort, if you would rather not click through that:

```sh
xattr -dr com.apple.quarantine /Applications/PhotoCleaner.app
```

PhotoCleaner is not notarized. It is open source and you can read every line of
it — [Source layout](#source-layout) is a short walk — but macOS cannot check
that for you, so it asks once.

## Build

```sh
./build.sh
```

This compiles `Sources/PhotoCleaner/**` with `swiftc` and produces
`dist/PhotoCleaner.app` — a minimal bundle with an ad-hoc signature. The bundle
exists only because macOS attributes the Photos permission prompt to a bundle
identity, and PhotoKit will not prompt without `NSPhotoLibraryUsageDescription`.

The web UI lives in `web/` and is compiled *into* the executable as raw Swift
string literals by `tools/embed-web.swift`; nothing is read from disk at runtime.

The bundle carries the keys macOS needs and nothing speculative: the usual
`CFBundle*` set, `NSPhotoLibraryUsageDescription` (required — PhotoKit will not
prompt without it), `LSMinimumSystemVersion` `15.0`, `NSHighResolutionCapable`,
`NSSupportsAutomaticGraphicsSwitching`, and `NSAppTransportSecurity` with
`NSAllowsLocalNetworking`. That last one is not decoration: the window is a
`WKWebView` loading `http://127.0.0.1:<port>`, App Transport Security applies to a
hosted web view but not to a page typed into Safari, and without that key the
window comes up blank. The build links to a temporary path and moves the
executable into place only on success, so a failed compile can never leave a
half-written binary behind.

`PHOTOCLEANER_VERSION` (default `1.0.0`) stamps `CFBundleShortVersionString` and
`CFBundleVersion`, and `PHOTOCLEANER_ARCH` (default: this Mac) picks the
architecture. The app reads its version back out of its own `Info.plist` for
`--version`, so the number in the About box is always the number of the build
you are actually running — there is no second constant to keep in step.

## Release

The DMG is published by pushing a tag. Nothing else publishes anything; `main` is
covered by CI only.

```sh
git tag v1.2.3 && git push origin v1.2.3
```

`.github/workflows/release.yml` then runs the same build, tests and smoke test as
CI, packages the DMG, and creates a GitHub Release with the generated changelog
attached. Roughly ten minutes, all of it on the runner.

```
dist/PhotoCleaner-1.2.3-arm64.dmg
├── PhotoCleaner.app
└── Applications → /Applications
```

Only `vN.N.N` tags release. Anything else — `v1.2`, `v1.2.3-rc1` — does not match
the workflow's tag filter and is silently ignored, so a pre-release tag publishes
nothing.

To try the whole thing locally before tagging:

```sh
./make-dmg.sh --version 1.2.3      # builds, packages, verifies, prints the path
./make-dmg.sh --version 1.2.3 --no-build   # package what is already in dist/
```

`make-dmg.sh` is system tools only — `hdiutil`, `ditto`, `codesign`,
`PlistBuddy`, `lipo`. It refuses to package an app whose stamped version or
architecture is not the one asked for, then mounts the image it just wrote and
checks the app, the `Applications` symlink, the bundle identifier and the
signature are all intact inside it. A DMG that mounts but installs nothing is not
released.

Releases are ad-hoc signed and **not notarized**, so first launch needs the
one-time right-click → **Open** described in [Install](#install). Signing with a
real Developer ID and notarizing would fix that, at the cost of secrets in the
workflow.

### Staying up to date

A build in `/Applications` can replace itself. **PhotoCleaner › Check for
Updates…** (⌘U) checks the release feed, downloads the DMG for this
architecture, verifies the app inside it, swaps it over the running bundle and
relaunches. The title-bar arc does the same thing with one click, and is also
where the progress is drawn. **Check for Updates Automatically** turns the
once-a-day check on and off; turning it on checks immediately rather than waiting
for the next launch.

Two things it will not do. It refuses to install while it is running from a
mounted disk image — move it to `/Applications` first — or into a folder this
process cannot write. And the app it installs is ad-hoc signed like any other
build, so macOS may ask for Photos access again after an update, for the same
reason it does after a rebuild.

## Run

```sh
./photo-cleaner
```

Builds if necessary, starts the server, opens **its own window** and prints:

```
  PhotoCleaner running at http://127.0.0.1:8765
```

The window is a `WKWebView` — the same WebKit engine as Safari — so
PhotoCleaner is a standalone application: its own Dock icon, its own menu bar
(⌘Q to quit, ⌘M to minimise, ⌘R to reload the interface, ⌘U to check for
updates, working clipboard in the filter fields), and it remembers its window
size and position. Closing the window quits the app, as any other Mac app does.

Nothing about the server or the UI changed to make this work. The window still
loads `http://127.0.0.1:8765` and the page still reaches the API with `fetch` and
a live `EventSource`. WebKit is only the thing drawing it, and that is
deliberate: serving the embedded assets through a `WKURLSchemeHandler` would be
tidier, but `EventSource` does not work on a custom scheme, and the live progress
read-out is much of the point.

To inspect the page, launch with the Web Inspector enabled and use
**Inspect Element** from the right-click menu:

```sh
PHOTOCLEANER_WEB_INSPECTOR=1 ./photo-cleaner
```

Other forms:

| Command | Effect |
|---|---|
| `./photo-cleaner --foreground` | Run in this terminal (Ctrl-C to stop), logs to stderr |
| `./photo-cleaner --port 8766` | Listen on a different loopback port |
| `./photo-cleaner --browser` | Use your default browser instead of a window |
| `./photo-cleaner --no-browser` | No interface at all; run as a plain server |
| `./photo-cleaner --help` (`-h`) | Print the built-in help and exit |
| `./photo-cleaner --version` (`-v`) | Print the version and exit |

`--port` takes 1–65535 and is checked by the launcher as well as the binary: an
out-of-range value is refused rather than quietly ignored by the binary's own
parse, which would leave the launcher waiting on a port nothing ever bound.

`--browser` and `--no-browser` never initialise AppKit, so they still start on a
Mac with no window server — over SSH, or from a `launchd` job. Only the default
windowed launch needs a logged-in desktop session.

`--foreground` (or `PHOTOCLEANER_FOREGROUND=1`) is handled by the **launcher**,
which runs the binary directly instead of going through `open`. The binary
itself parses only `--port`, `--browser`, `--no-browser`, `--help`/`-h` and
`--version`/`-v`; any other argument is ignored.

The interface is served **only on `127.0.0.1`**. The listener is bound to the
loopback address and additionally rejects non-local peers, so the service is
never reachable from your LAN.

A second launch is harmless: if PhotoCleaner already serves that port it points
the window of the running instance and exits. Nothing is rebuilt implicitly —
the launcher warns you when `web/` or `Sources/` is newer than the built app.

## Photos permission

On first launch macOS asks whether PhotoCleaner may access your Photos library.
Grant it. The permission can be changed later in
**System Settings › Privacy & Security › Photos**.

If access is denied the interface still loads and explains the problem; nothing
is scanned.

Because a rebuild produces a new ad-hoc signature, macOS may ask again after you
rebuild — or after a self-update, which installs a freshly signed bundle. (A
Developer ID signature would keep the grant stable; ad-hoc is what a
dependency-free local build can do.)

## What it does

1. **Scans** the library metadata (identifier, dates, dimensions, favourite,
   screenshot flag) in batches and stores it in SQLite. Photos added, edited or
   deleted since the last run are reconciled automatically.
2. **Scores** every photo and clip with Apple's aesthetics model, in the
   background, with bounded concurrency, while the interface stays usable. A
   still is one frame; a clip is sampled at 10%, 50% and 90% of its duration and
   takes the **median** of those scores. Clips are never grouped — a FeaturePrint
   is a statement about one photograph, not about a moving sequence.
3. **Filters** by score range. The slider's limits are the **observed** minimum
   and maximum in your library — the scores are *not* normalised to 0…1, and
   PhotoCleaner never assumes they are. Drag either handle; **Reset** puts both
   back on the observed bounds.
4. **Inspects** any photo in a large preview with keyboard navigation
   (`←` / `→`, `Space` to toggle the preview, `Esc` to close).
5. **Shows any photo in All Photos** — the whole library in date order, grouped by
   day, with the photo you came from highlighted in the middle of its series.
6. **Deletes** the photos you select, straight through PhotoKit, from the
   selection bar's **Delete** button, `⌫` or `Delete`, a photo's right-click menu,
   or the preview's own **Delete**. One step, no prompt, and the count on the
   button is the number of photos that go.

### All Photos

Sometimes the question is not "which photos are ugly?" but "what was that run of
shots on the same evening, and which one is the keeper?". **Show in All Photos**,
on any tile or in the lightbox, opens the library in reverse-chronological order
with day separators, and puts the photo you started from in the middle of the
window rather than at the top.

The score is deliberately ignored here — this view is about chronology, not
ranking — and the score filter cannot narrow it. Pages load in both directions, so
you can walk backwards through older photos as well as forwards.

`Esc`, or **← Back**, returns you to the grid exactly where you left it, with your
selection intact.

Because ordering is anchored on the photo's own date, opening a photo from years
ago costs the same as one from this morning. The window contains the photos
PhotoCleaner has **scored**: photos whose pixels live only in iCloud are not scored
by default, and the interface states how many those are rather than implying you
are looking at everything.

### Sorting

Score ↑ (lowest first, the default), Score ↓, Newest, Oldest. Odd, dark,
accidental and duplicated-looking shots surface immediately at the low end.

The control panel reads in the order you use it: **Aesthetics** (the score range),
then **Album**, then **Media** (All / Photos / Videos) — all three of which
*narrow* 53,000 assets to something you would actually look at — and then **Sort**
last, pushed to the far right, because it is the one control that changes no
membership. It only reorders what is already on screen, so it is the final
decision about how to walk the result.

### The grid

A tile is an asset and a score, and nothing else. No caption: not the date,
not the album, not a row of badges underneath. Hovering a tile names all three,
the lightbox shows them, and the tile's accessible name spells them out for a
screen reader — but the grid itself stays a contact sheet you can actually scan.

Tiles are **1px apart**, with 1px around the grid, so the photographs run together
the way they do in Photos. Every tile is a **square** and each asset is
cropped to fill it: a square is the only shape that makes a grid of 53,000 of
them uniform, and uniformity is what makes it scannable.

A clip's tile is its poster frame — the same thumbnail route a still uses, because
`PHImageManager` already answers a video with a decoded frame — and it says so: a
duration badge and a play glyph. Opening one puts a `<video>` element on the
preview stage, fed by `GET /api/photo/{id}/video`. It never autoplays and preloads
metadata only: paging through a grid of clips should not make noise or pull a whole
export off the disk for something you are only looking at. Nothing is transcoded or
re-muxed; the bytes are what Photos holds.

One thing is drawn *on* the photo rather than beside it, because it changes what an
action **does**: a **♥** for a favourite, which is also the button that sets it.
Protection from deletion rides on the same glyph: a heart means the photo is
excluded from bulk deletion, and the tooltip and the tile's accessible name both say
so. There is no switch for it. Excluding favourites is not a preference you can
weaken, so a stored `protectFavorites: false` is ignored on load and the API refuses
to set one.

The same heart is on a group member's thumbnail, and it does the same thing there.
It used to be different: a mark you could read but not press, and only once the
photo was already a favourite. "The heart sets the favourite" is one promise, and it
holds everywhere a heart is drawn.

### While the library is being analysed

Analysis progress lives in the title bar: the phase, a bar and a percentage, and
nothing else. The running commentary — analysed/total, rate, ETA, failures — is
one click away (or a hover, since it is the tooltip too). If a run **stops**, the
detail opens by itself, because that is the text you need to read; **Retry
failures** re-queues what failed.

### Selection, and what "all" means

- **Click** a photo to select it, **shift-click** for a range, **double-click**
  to inspect. **Space** inspects the focused photo and inspects it again to put it
  away — the same toggle everywhere, including on a group's member thumbnails.
- **Select all matching** selects *every* photo matching the current filter — not
  just the page you have scrolled to. The filter is *saved* at that moment, and
  the interface says so: moving the sliders afterwards does **not** change what
  will be deleted. If you change the filter while an "all matching" selection is
  live, deletion is blocked until you either update the selection to the current
  filter or clear it.
- The saved filter is a **snapshot**. Once the selection exists, the live sliders
  cannot change what it covers — "all" can never quietly grow under you.

### Deleting

Deletion is **one step**. Select, press **Delete**, and the photos are gone:

- the **Delete** button in the selection bar, labelled **Delete *N* photos** with
  the count the server itself resolved;
- **⌫** or **Delete**, with or without a modifier — on a Mac keyboard the key
  labelled delete *is* Backspace, and both mean the same thing;
- **Delete** on a photo's right-click menu, or on the preview's own bar — both
  acting on the photo you pointed at, or on the whole selection when it is part of
  it, and both saying so in the menu's footnote.

There is no staged list, no second step and no **⌘Z**: a deletion goes to
**Recently Deleted** and the way back from there is Photos, not PhotoCleaner. What
replaces the two-step guard is on the server and it is stronger — the request
carries the **fingerprint of the set the preview resolved**, so if the library
resolves to something else by the time you press Delete, the deletion is **refused**
rather than applied to a set nobody saw. The count on the button is that resolved
number, so "Delete 12 photos" means twelve photos.

A photo the server could not resolve leaves **Delete** greyed out rather than
offering a deletion of unknown size.

### Favourite protection

**Always on.** Favourites are shown, marked with the heart, and **excluded
server-side** from every bulk selection and deletion. There is no switch: the
server refuses a request that sets it off, and a `settings.json` written by an
earlier build that stored `false` is read with protection on anyway.

## Deletion

Deletion goes through `PHPhotoLibrary.performChanges` /
`PHAssetChangeRequest.deleteAssets`, in bounded chunks. Photos then does exactly
what it does for any deletion: the items move to **Recently Deleted**, and iCloud
Photos syncs the removal to your other devices. You can recover them from
Recently Deleted like any other photo.

A deletion is sent with the **fingerprint of the set the preview resolved**, so a
library that changed between the count you read and the Delete you pressed is
refused rather than deleted. The selection stays exactly as it was, its count is
re-read, and you decide again on the new number.

PhotoCleaner **never**:

- writes to `Photos Library.photoslibrary`,
- opens or mutates the Photos SQLite databases,
- touches image files on disk,
- bypasses Photos authorization,
- offers a "delete everything below score X" command.

Only identifiers the running instance already knows about can be deleted, so a
stray request cannot reach an arbitrary asset.

## Privacy

- Every score is computed **on this Mac**, by Apple's on-device model.
- **No telemetry, no analytics, no crash reporting, no external fonts, no CDN,
  no remote icons, no image uploads.** The interface has no external resources of
  any kind and works with the network disconnected.
- The process holds exactly one listening socket, `127.0.0.1:8765`, and the
  only address it will ever open is that one.
- There is exactly one outbound request, and it is the update check: a single
  HTTPS `GET` of this repository's public release feed, at most once a day, off
  an in-memory session with no cache or cookie storage. **PhotoCleaner ›
  Check for Updates Automatically** turns it off. Nothing is uploaded with it.
- The only authenticated network access is the one you opt into: PhotoKit
  fetching an iCloud-stored original (see below).

## iCloud behaviour

By default **"Download from iCloud when required" is off**, so a first run never
silently pulls down an entire optimized library.

- Assets whose pixels are not on this Mac are marked *not on this Mac*, counted
  separately from failures, and left alone. They are not errors and are not
  retried.
- **Thumbnails never fetch from iCloud**, regardless of this setting — scrolling
  past thousands of photos must not trigger thousands of downloads. A clip's
  poster frame is no exception. Such tiles show an "In iCloud" placeholder.
- Turning the option on re-queues everything that was skipped and lets analysis,
  lightbox previews and clip playback fetch originals.
- Playing a clip that lives only in iCloud is refused with a message naming the
  setting, rather than reported as a missing video.

On an optimised library a large share of assets are cloud-only: in the library
these numbers were measured against, **15,600 of 52,661** stills (**30%**) were
not local.

## Cache and logs

| What | Where |
|---|---|
| Score cache | `~/Library/Application Support/PhotoCleaner/cache.sqlite` (plus `-wal`/`-shm`) |
| Preferences | `~/Library/Application Support/PhotoCleaner/settings.json` |
| Update scratch | `~/Library/Application Support/PhotoCleaner/update/` (only while an update is running) |
| Clip exports | `~/Library/Application Support/PhotoCleaner/video-cache/` (bounded; every file is reproducible from Photos) |
| Log | `~/Library/Logs/PhotoCleaner/PhotoCleaner.log` (rotates at 5 MB) |

The cache is a plain SQLite database — no server, no external dependency. Its
size is dominated by the compressed Vision payloads, not by the scores: on the
library measured below it is **~190 MB**, of which ~150 MB is `asset_signals`
and the rest is asset rows, album membership and materialised groups. The live
figure is `cacheBytes` in `GET /api/status`. Scores survive restarts and
completed assets are never re-scored; only new, edited or upgraded-analyser
assets are queued.

### Remove everything PhotoCleaner stores

```sh
rm -rf ~/Library/Application\ Support/PhotoCleaner ~/Library/Logs/PhotoCleaner
```

That removes the score cache, the preferences, any update scratch and every cached
clip export: they are all under Application Support, and the log (with its rotated
`PhotoCleaner.log.1`) lives in Logs. Clip exports are worth naming explicitly
because they are the largest thing the app can leave behind and the least
interesting — every one of them is reproducible from Photos, and the next play of
the clip re-exports it. Then delete `dist/` to remove the built app. Your Photos
library is untouched — PhotoCleaner adds nothing to it except the deletions you
perform.

What the app writes *outside* those two directories is not under its control,
and none of it holds library data, a score or a cookie:

| What | Why it is there |
|---|---|
| `~/Library/Preferences/com.alastorid.photocleaner.plist` | one key, the window's frame, written by `NSWindow`'s autosave |
| `~/Library/Caches/com.alastorid.photocleaner/` | created empty by Foundation's URL loading; `smoke-test.sh` fails the run if it ever holds a cached response |
| `~/Library/HTTPStorages/com.alastorid.photocleaner/` | the same, for cookies |
| `~/Library/Saved Application State/com.alastorid.photocleaner.savedState` | written by macOS itself when the app quits cleanly |

Deleting the cache is safe but not free: the next launch re-scores the whole
library from scratch, exactly as a first run does.

## Performance

Measured on an M3 with a 52,661-still library, concurrency 4, 1024 px analysis
inputs:

| Metric | Value |
|---|---|
| First full analysis | **2 min 27 s** (147 s, from the log); ~250 scored/s, ~360 photos/s once the iCloud-only skips are counted |
| Resident memory | ~180 MB, flat in library size (assets are never held in memory) |
| Cache size | ~190 MB, ~150 MB of it compressed Vision payloads |
| 60 cold grid thumbnails | 1.4 s sequentially (~23 ms each) |
| CPU | ~3% — inference runs on the Neural Engine |

The 147 s comes straight from the log — `analyzing with concurrency 4 …` to
`analysis run finished` on the first launch — and it resolved **every** photo.
The cache it left behind now reads 52,661 rows: 37,061 scored with the aesthetics
model, 15,600 skipped because their pixels are iCloud-only, none failed. A
library like this one is never finished: photos arrive and are deleted, so treat
every count here as a snapshot rather than a constant.

The `N photos/sec` shown while a run is in progress is the engine's own rolling
rate, and it counts the cloud-only skips as well as the real inferences, so it
reads high and is **not** an inference throughput. The ETA beside it inherits
that and is therefore optimistic when many photos live only in iCloud.

### Why 1024 px?

The analysis input is bounded to a 1024 px longest edge, aspect-preserving. This
was measured, not guessed: for the same asset, a 256 px input drifts by up to
**0.135** in score, while 512 / 1024 / 2048 px agree within **0.02**. 1024 is the
cheapest point on that plateau — about 4 MB of RGBA per in-flight image, and no
full-resolution HEIC/RAW decode.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Photos access is required" banner | Grant access in System Settings › Privacy & Security › Photos, then relaunch. |
| Many photos marked *not on this Mac* | They live only in iCloud. Enable "Download from iCloud when required" if you want them scored. |
| A tile shows "In iCloud" | Thumbnails deliberately never fetch from iCloud. Open the photo, or enable downloads. |
| Port already in use | PhotoCleaner is probably already running; it will open the existing instance. Otherwise use `--port 8766`. |
| macOS asks for Photos permission again after a rebuild | Expected with an ad-hoc signature (see above). |
| Build fails with `redefinition of module 'SwiftBridging'` and "this SDK is not supported by the compiler" | The Mac's Command Line Tools install is broken or partially updated, so its SDK and compiler are different Swift builds. `build.sh` detects this and prints the fix; in short, reinstall the matching "Command Line Tools for Xcode" from [developer.apple.com/download/all](https://developer.apple.com/download/all/) (or install Xcode and run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`). |
| Build uses a different Swift than `swift --version` reports | On purpose: `build.sh` resolves `swift`/`swiftc` through `xcrun`, so a toolchain on `PATH` (Homebrew, Swift.org) can never be mixed with this Mac's SDK. |

## API

The UI is a thin client over a small JSON API. Nothing destructive is reachable
with `GET`.

```
GET  /                            embedded UI
GET  /app.css, /app.js            the rest of the embedded UI
GET  /favicon.ico                 204, nothing to serve
GET  /api/status                  library + analysis status (also pushed over SSE)
GET  /api/photos                  ?lo&hi&sort&favorites&album&media&limit&cursor&offset
GET  /api/albums                  the album chips: indexed albums, unassigned count, smart albums
GET  /api/timeline/around         ?id={anchor}&limit — one page either side of a photo
GET  /api/timeline/page           ?direction=older|newer&cursor&limit — All Photos paging
GET  /api/events                  Server-Sent Events; event: status
GET  /api/photo/{id}              one asset's metadata
GET  /api/photo/{id}/thumbnail    ?size=128|256|384|512 — a video's poster frame too
GET  /api/photo/{id}/preview      ?size=512…4096 (degrades to the best local rendition)
GET  /api/photo/{id}/similar      the Similar Group this photo is in — {groupId?, totalCount, analyzed}
GET  /api/photo/{id}/video        one clip, with byte-range support; 409 if it is iCloud-only
GET  /api/groups                  ?order&limit&offset&album — every group, largest first
GET  /api/group                   ?id&order&album — one group, its members in the requested order
POST /api/albums/index            read album membership from Photos again
POST /api/favorites               {ids, favorite} — set or clear the heart
POST /api/photos/reveal           {id} — mark one photo as viewed in Photos
POST /api/groups/rebuild          group the library again
POST /api/selection/preview       resolve a selection without changing anything
POST /api/delete                  delete through PhotoKit
POST /api/settings                {downloadFromICloud?, concurrency?, groupWindowSeconds?, …}
                                  (`protectFavorites` is accepted but refused as
                                  false — favourite protection is not a setting)
POST /api/analysis/retry          re-queue failed / skipped assets
POST /api/library/rescan          re-read the library and reconcile
```

`sort` ∈ `score_asc` (default) `| score_desc | date_desc | date_asc`;
`favorites` ∈ `include | exclude | only`.
`media` is `all` (default) `| images | videos`, and it means the same thing on
`/api/photos`, `/api/groups` and `/api/group` — see **Videos** below for what it
does to a group. Anything else is a **400 naming the three valid values**, never a
silent fall back to `all`.
`album` is `all` (default) `| none` (in no album) `| an album identifier`, and
means the same thing on `/api/photos`, `/api/groups` and `/api/group` — see
**Similar Groups** below for what it does to a group.
Asset identifiers contain `/`, so URL-encode them (`…%2FL0%2F001`); the server
also accepts unencoded slashes.

Every `PhotoRow` on the wire carries:

| field | |
|---|---|
| `mediaType` | `1` a still, `2` a video — `PHAssetMediaType` raw values, stored raw rather than translated so a row and the cache's `assets` table cannot disagree. **Always present**: a client must not read its absence as "image". |
| `duration` | seconds, **video only**. **Omitted** for a still, never `null` — and never `0`, which would claim a zero-length video exists. |

`filter.media` is echoed back on every page response, so a client can tell the
filter it *asked for* from the one the server *applied*, and renders the latter.

The two `/api/timeline/*` routes are read-only and take no body. They order by
**date alone** — the score is used only as the widest bound the cache can express,
never as an ordering key — and they deliberately ignore `lo`, `hi` and `favorites`,
so the All Photos window cannot be narrowed by a filter. Both anchor
their keyset on the photo's own `(date, id)`, so cost is independent of library
size and of the photo's age. `older` is descending from the anchor; `newer` is
ascending from it (nearest first), so a client displays newest-first by reversing.

Optional fields are **omitted**, not sent as `null`: the encoder drops nil
optionals, so `nextCursor`, `bounds.min`, `bounds.max`, `score.min`,
`score.max`, `analysis.etaSeconds`, `analysis.lastError`, `analysis.startedAt`,
`PhotoRow.date` and `PhotoRow.duration` may be missing from a response entirely. A
client must treat an absent key and an explicit `null` identically.

`GET /api/photo/{id}/video` is the one route that is **not** a JSON answer. It
supports `Range` — `bytes=a-b`, `bytes=a-` and `bytes=-suffix` — so seeking works.
An unparseable range and a multi-range one are ignored and answered `200` with the
whole file; a start past the end is `416`; and a clip that exists but is stored only
in iCloud is **`409` naming the setting** that turns it into a `200`, because a
`404` would read as "this video is gone". Nothing is transcoded or re-muxed: the
bytes are what Photos holds, exported once and cached.

## Source layout

```
Sources/PhotoCleaner/
  main.swift                entry point; macOS 15 guard
  App/PhotoCleanerApp.swift launch sequence, banner, signals
  App/Presentation.swift    window / browser / headless, shutdown relay
  App/AppWindow.swift       NSWindow + WKWebView, navigation policy
  App/AppDelegate.swift     NSApplication lifecycle, menu, terminate handshake
  App/MainMenu.swift        the menu bar
  App/UpdateIndicator.swift the title-bar arc that drives the updater
  Support/                  paths, logging, preferences, SSE fan-out
  Model/Records.swift       asset/filter/sort/cursor types
  Library/PhotoLibrary.swift    all PhotoKit access (auth, enumerate, images, delete)
  Library/VideoLibrary.swift    the only file that imports AVFoundation: frames, playback, export
  Analysis/VisionAnalyzer.swift Apple's aesthetics, FeaturePrint and face requests
  Analysis/CacheStore.swift     SQLite actor: schema, reconciliation, queries
  Analysis/AnalysisEngine.swift scan + bounded analysis run loop, progress
  Analysis/AlbumIndexer.swift  lazy album membership, one album at a time
  Analysis/SimilarGroups.swift  the group builder, face aggregation, Best Shot ranker
  Analysis/SimilarGroupEngine.swift  the background grouping pass and Tier 3 faces
  Analysis/SignalCompression.swift    zlib + Codable for the cached Vision payloads
  HTTP/                     Network.framework server, router, API
  Update/                   self-update: release feed, install target, installer, actor
  Web/                      embedded-asset accessor + generated file
web/                        index.html, app.css, app.js (the editable UI source)
Tests/                      the regression suite, one file per area; see Tests/README.md
tools/embed-web.swift       folds web/ into the executable
tools/make-icon.swift       draws AppIcon.icns at build time
tools/web-ui-harness.mjs    the web/ client in jsdom, against a running server
tools/web-ui-tests.mjs      its checks
.github/workflows/ci.yml    build + test + smoke on every push and pull request
.github/workflows/release.yml   the vN.N.N tag → DMG pipeline
docs/ARCHITECTURE.md        the engineering record: measurements, invariants, limits
docs/WEB-UI-TESTS.md        how to run and extend the jsdom client tests
build.sh                    compiles and assembles the .app bundle
make-dmg.sh                 packages it as a drag-to-Applications .dmg
run-tests.sh                the regression suite
smoke-test.sh               read-only audit of the build, cache and filesystem state
photo-cleaner               launcher
```

**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is where the engineering decisions
live** — the measured environment and API behaviours, the schema, the invariants that
look like style but are not, what is deliberately not implemented, and the known
limitations. This README is what the tool does; that file is why.

## Videos

Clips are **first-class assets**. They are enumerated, scored, browsable in the grid
and in All Photos, playable in the preview, favouritable and deletable under exactly
the same protections as a photograph. Nothing about the deletion model changed: the
same one-step Delete, the same server-side favourite protection, the same fingerprint.

### What a clip is scored on

A still is one frame. A clip is sampled at **10%, 50% and 90%** of its duration —
never at 0, because the first frames are usually leader or black — and takes the
**median** of those three scores.

The median, not the mean: a black leader or a blown highlight would drag a mean, and
one bad frame must not decide the score for a clip that is two minutes long. Three
samples with the median survives it.

### The media filter

**Media** — All / Photos / Videos — sits beside **Sort** in the control panel and
narrows the grid the same way **Aesthetics** and **Album** do. All is the default,
because a video is an asset and an asset is what this tool has always shown.
Videos appear in **All Photos** automatically, and that view is deliberately
unfiltered: it is about chronology, not ranking, so it has no media control.

The filter is part of the selection snapshot. Take **Select all matching** on a
Videos-filtered grid and the snapshot pins the media dimension, so switching to
Photos afterwards leaves the selection stale and **blocks** deletion until you
re-snapshot or clear it — a snapshot that forgot the media dimension would resolve to
every photo *and* video in the library.

### Videos are never grouped — and that is a decision, not an oversight

Similar Groups answers "are these alternate captures of the same shot?". A video's
FeaturePrint would be **one frame of a clip that may pan away from the very thing
the still shows**, and the FeaturePrint threshold (`maxDistance`, default 0.35) and
the 120 s capture window were both calibrated on stills, against bursts and retakes.
Admitting clip-frames changes what a distance *means* — silently, for every existing
group, on every library that already has groups stored.

So a clip scores, browses, plays, is favourited and is deleted, and it never becomes
a group member. Two places enforce it, which is deliberate: `refreshFeaturePrintQueue`
excludes clips so the backfill never generates a vector for one, and `analyzeFrames`
returns none for a multi-frame subject. One gate would be a rule; two is a
consequence you cannot route around.

**All Photos** is unaffected — it is chronological, and a clip has a place in a
series like anything else.

### Playing a clip

Opening one puts a `<video>` on the preview stage, fed by
`GET /api/photo/{id}/video` with the export cached under Application Support.

- **It never autoplays**, and preloads metadata only. Paging through a grid of clips
  should not make noise, and looking at a clip should not pull a whole export off the
  disk.
- **It is paused and released on paging and on close.** A retained `<video>` holds a
  decoder and its network stream open; pausing before dropping the source is what
  stops audio continuing under the next photo.
- **Nothing is transcoded.** The bytes are what Photos holds, exported once through
  `AVAssetExportPresetPassthrough`. On any iPhone-shot library since 2017
  that means **HEVC**, which Safari and the app's own window play and **Chrome does
  not** — accepted, because the shipped presentation *is* the window, and a
  transcode of a 4 GB clip on a click is not a tradeoff worth making. See
  [ARCHITECTURE §10](docs/ARCHITECTURE.md) for what measuring that would take.

### What a clip's tile looks like

A clip's tile is its **poster frame**, from the same thumbnail route a still uses —
`PHImageManager` already answers a video with a decoded frame, so there is no second
image path and nothing new that can be wrong. It carries a **duration badge**
(`m:ss`, or `h:mm:ss` past an hour) in the corner opposite the score, and a **play
glyph**, because at thumbnail size a poster frame is indistinguishable from a
photograph of the same moment — which is the confusion that makes someone delete a
clip believing they had a still in front of them.

The media type and length also go in the tile's accessible name and tooltip, which is
where this interface already puts everything a tile does not print. A clip with no
length yet prints the type alone: `0:00` would claim a zero-length video exists.

## Similar Groups

Photos that are alternate captures of approximately the same shot — the fifteen
frames of a burst, the three takes of a portrait — grouped together so you can pick
the best one. Opened with **Similar Groups…** in the control panel.

### Albums apply here too

The album filter is not a grid-only thing. Filter the grid to an album and open
Similar Groups, and you get the groups **in that album** — a group is listed as
soon as *one* of its photos is in it, and the members on each strip are that
album's members. The heading names the album, and a group that reaches beyond it
carries a badge saying how many photos were left out.

Both halves matter, and they are separate decisions:

- **Which groups are listed** — any member, not all of them. A burst split across
  two albums is still one burst, and it is still one cleanup decision. Requiring
  every member to be in the album would hide exactly the groups you get when you
  are comparing two albums.
- **Which members are on a strip** — only the album's. The card's photo count is
  of what it shows, and the badge carries the group's real size, so a card never
  claims a group is three photos when it is sixty.

An empty album-filtered list says so in those terms — "No similar groups in
*Abao*" — rather than the library-wide "no similar groups found", which would be a
claim about your library rather than about the album you asked about. **No album**
is a real bucket here exactly as it is in the grid.

An album PhotoCleaner has not read is refused with a 400, the same as in the grid,
rather than being quietly treated as no filter at all.

### Show Similar Photos

Right-click any photo — in the score grid, in All Photos, in a group, or in the
lightbox — and choose **Show Similar Photos** to jump straight to the group that
photo belongs to.

It is a **show**, not a find. Grouping already happened when the FeaturePrints were
analysed, and the answer is sitting in `similar_group_members`. So the whole action
is one `GET /api/photo/{id}/similar` — an indexed read of one table — followed by
navigation. No image is decoded, no FeaturePrint is generated, no pair is compared
and no Vision request is made, which is why it can be a menu item at all. There is
one grouping implementation and one group browser; this is a second doorway into
them, not a second algorithm.

The originating photo is marked with an accent ring and scrolled into view, and it
stays where the sort put it. The mark is not a selection: nothing is queued for
deletion, and the two states never share a class.

Two answers are possible when there is no group, and they are different facts:

| | Shown |
|---|---|
| analysis has reached the photo, no neighbours | "No similar photos found." |
| analysis has not reached it yet | "Similar-photo analysis is not available for this photo yet." |

Neither creates a group of one. A group needs two members to mean anything, and a
single photo is not a result. A clip asks the first question permanently: it is
scored, so analysis has reached it, and it has no FeaturePrint, so it is in no
group. It has no group to show and nothing to be unavailable for.

The lookup answers from **group membership**, not from the group list. A list is a
presentation with rules of its own — it may omit groups with nothing worth cleaning
up — while "which group is this photo in" is a property of the photo. A group of
three where two members are protected favourites still opens, and all three come
back, because that is a similarity question rather than a cleanup one. Favourite
protection behaves exactly as everywhere else throughout.

Back returns to wherever you came from — the same scroll position, the same filters,
the same selection. All Photos costs nothing to return to because its window is
hidden rather than torn down.

Two ideas are used for two separate jobs, and never mixed:

**Which photos belong together** — Apple's `GenerateImageFeaturePrintRequest`
compares how alike two images look. FeaturePrint distance only ever answers "are
these alternatives?", never "which is better?", so it never enters a quality score.

**How the group is ordered** — two sorts:

- **Aesthetics** — Apple's `overallScore`, exactly as returned.
- **Best Shot** — PhotoCleaner's own ranking, for groups containing faces.

`Show Similar Photos` uses that same control, and defaults to Aesthetics descending
— the group is not reordered around the photo you came from, because a marker that
moved the strip would be making the ranking a lie.

## Best Shot, and why it is not a formula

`overallScore` is measured over −0.9399…+1.0000 on a real library and face capture
quality runs 0…1. A formula like `aesthetics * 0.6 + faceQuality * 0.25` silently
asserts a relationship between two instruments that measure different things in
different units. So each signal is reduced to its **rank within the group** — best
member 1.0, worst 0.0 — and the ranks are blended. Rank is unit-free, so the blend
means what it says.

The two signals genuinely disagree. One measured burst on a real library:

| | aesthetics | face capture quality |
|---|---|---|
| frame 1 | +0.7515 | 0.585 |
| frame 2 | +0.7061 | 0.437 |
| frame 3 | +0.7021 | 0.605 |

Aesthetics ranks frame 1 first; face capture quality ranks it second. A third group
sees frame 3 promoted from 4th to 3rd. That is the point of having both.

**Face quality is a minimum, not an average.** For two frames of a group of three:

| | person 1 | person 2 | person 3 |
|---|---|---|---|
| photo A | .91 | .88 | .24 |
| photo B | .85 | .82 | .80 |

A mean rates A at .68 and B at .82 — "A is a bit worse". The truth is that one
person was captured badly in A and everyone was captured evenly in B. The worst
face is the honest aggregate for a tool deciding which capture to keep.

Nothing here deletes anything. A higher Best Shot value means a better candidate to
*keep*; deletion remains an explicit, confirmed action through the same protected
route as always.

## The settings are measured, not guessed

`GET /api/groups` reports what each knob is doing. The defaults come from measuring
a 53k-photo library:

**FeaturePrint distance**, against real bursts (frames ≤2 s apart) rather than
everything inside a time window — the difference matters, because a 120 s window on
that library holds up to 1,499 photos:

| pair kind | n | min | p50 | p90 | max |
|---|---|---|---|---|---|
| same burst | 28 | 0.020 | 0.054 | 0.282 | 0.535 |
| other bursts | 437 | 0.472 | 0.990 | 1.195 | 1.451 |

At **0.35** the grouping is 93% complete with **zero** cross-burst merges; at 0.55
recall reaches 100% but 6 wrong merges appear. The two distributions overlap in
[0.47, 0.53], so no threshold is exact. 0.35 is chosen because a missed merge costs
one manual sort while a false merge silently gathers unrelated photos.

**Capture-time window**, 120 s by default, is what makes grouping affordable: an
all-pairs comparison over 53k photos is ~1.4 billion distance computations, while
the time-restricted set is ~3.9 million.

Both are configurable, along with the face weight, the minimum face size that counts
as significant, and a maximum group size — the last because capture time is a weak
restriction in practice, and without a bound a whole event would arrive as one
1,499-member "group". Changing any of them rebuilds automatically.

## Cost, and the cache

A FeaturePrint is 768 floats: 3,072 B raw, 4,351 B as JSON. zlib brings that to
about **2.5 KB** — 2,562 B measured across the 37,056 vectors in the cache above —
so the vectors alone are **~90 MB**, by far the largest thing in it. It is
compressed because `FeaturePrintObservation` cannot be rebuilt from its raw payload
through any public API: its `Codable` conformance is the only route in, and that
round trip was verified bit-exact (worst distance error `0.0` across 400 pairs).

Computing one alongside the aesthetics score costs little: run together on the same
decoded 1024 px image they take **7.2 ms**, against 5.0 ms for aesthetics alone.

Photos scored before this version are queued for a vector automatically. Their
existing scores are never recomputed or discarded — they keep the score they have.

## Not implemented (by design)

Similar Groups deliberately stops here. These are real Vision capabilities that are
*not* used, because nothing showed them improving either grouping or ordering:

- **Image registration** (translational and homographic). A second-stage test for
  pairs that are close in both time and distance, to tell "same shot" from
  "merely similar scene". Only worth adding if grouping shows wrong merges.
- **Saliency** (attention-based and objectness-based). Useful for comparing
  *framing* between captures, but only as context — not as another score to add.
- **Face landmarks.** Supporting information at most, and only for comparing
  near-identical portrait frames.
- **Lens-smudge detection.** A technical capture signal that could become a Best
  Shot penalty; it must not affect grouping.
- Human pose, hand pose, animal recognition, OCR, foreground masks, object
  tracking, optical flow, trajectories, contours.
- Personal preference learning.

The test for any of these is the same: does it materially improve either same-shot
grouping or within-group ordering?

The same reasoning rules out the larger features: no threshold that deletes anything
on its own, no way to re-score the whole library, and no face identity recognition.

## Contributing

Issues and pull requests are welcome. Two things make this project unusual:

- **There is no Swift package manager, and no runtime dependencies.** SwiftPM does
  not work on the target machine, so `build.sh` and `run-tests.sh` drive `swiftc`
  directly and there is no `Package.swift`. Do not add one.
- **`package.json` is for the test harness only.** It declares `jsdom` so the
  optional web-UI suite in [`docs/WEB-UI-TESTS.md`](docs/WEB-UI-TESTS.md) can run,
  and npm fetches it at install time. Nothing about the shipped app resolves it,
  `node_modules/` is gitignored, and no third-party code is vendored into the tree —
  the repository carries the manifest and the lockfile, not the packages. If a
  dependency ever needs to reach `build.sh` or a release, that is a different
  decision and belongs in an issue first.
- **Please add a test with any behavioural change, and prove it can fail.** Revert
  the fix in a scratch tree and watch the new case go red. A test that has never
  failed is not evidence of anything.
- **The `web/` client is tested separately.** Changes to `web/app.js`, `web/app.css` or
  `web/index.html` need `node tools/web-ui-tests.mjs` as well as the Swift suite —
  `run-tests.sh` compiles that code into the binary but asserts nothing about how it
  behaves. [docs/WEB-UI-TESTS.md](docs/WEB-UI-TESTS.md) covers how to run it, what
  jsdom cannot do on its own, and what it is and is not meant to cover. The client's
  own invariants are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §8.

`./run-tests.sh` needs no Photos library and no network, and `./smoke-test.sh` audits
the build and the filesystem read-only. CI runs both on every push to `main` and
every pull request.

## License

MIT — see [LICENSE](LICENSE).

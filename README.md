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
- A Swift toolchain (Xcode **or** just the Command Line Tools) to build. There is
  no package manager, no dependency resolution and no third-party runtime.

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

The bundle carries only the keys it needs: `NSPhotoLibraryUsageDescription`
(required — PhotoKit will not prompt without it), `LSMinimumSystemVersion`
`15.0`, `CFBundleIdentifier` `com.alastorid.photocleaner`, `CFBundleVersion`,
`NSHighResolutionCapable` and `NSSupportsAutomaticGraphicsSwitching`. The build
links to a temporary path and moves the executable into place only on success, so
a failed compile can never leave a half-written binary behind.

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

`make-dmg.sh` is `hdiutil` and nothing else. It refuses to package an app whose
stamped version or architecture is not the one asked for, then mounts the image
it just wrote and checks the app, the `Applications` symlink, the bundle
identifier and the signature are all intact inside it. A DMG that mounts but
installs nothing is not released.

Releases are ad-hoc signed and **not notarized**, so first launch needs the
one-time right-click → **Open** described in [Install](#install). Signing with a
real Developer ID and notarizing would fix that, at the cost of secrets in the
workflow.

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
(⌘Q to quit, ⌘W to close, ⌘R to reload, working clipboard in the filter fields),
and it remembers its window size and position. Closing the window quits the app,
as any other Mac app does.

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

`--browser` and `--no-browser` never initialise AppKit, so they still start on a
Mac with no window server — over SSH, or from a `launchd` job. Only the default
windowed launch needs a logged-in desktop session.

`--foreground` (or `PHOTOCLEANER_FOREGROUND=1`) is handled by the **launcher**,
which runs the binary directly instead of going through `open`. The binary
itself parses only `--port`, `--browser`, `--no-browser`, `--help`/`-h` and
`--version`/`-v`; any other argument is ignored.

Sounds are served **only on `127.0.0.1`**. The listener is bound to the loopback
address and additionally rejects non-local peers, so the service is never
reachable from your LAN.

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
rebuild. (A Developer ID signature would keep the grant stable; ad-hoc is what a
dependency-free local build can do.)

## What it does

1. **Scans** the library metadata (identifier, dates, dimensions, favourite,
   screenshot flag) in batches and stores it in SQLite. Photos added, edited or
   deleted since the last run are reconciled automatically.
2. **Scores** every still photo with Apple's aesthetics model, in the background,
   with bounded concurrency, while the interface stays usable.
3. **Filters** by score range. The slider's limits are the **observed** minimum
   and maximum in your library — the scores are *not* normalised to 0…1, and
   PhotoCleaner never assumes they are. Drag either handle, or type exact numbers.
4. **Inspects** any photo in a large preview with keyboard navigation
   (`←` / `→`, `Space` to toggle the preview, `Esc` to close).
5. **Shows any photo in All Photos** — the whole library in date order, grouped by
   day, with the photo you came from highlighted in the middle of its series.
6. **Deletes** the photos you select, straight through PhotoKit, from the
   selection bar's **Delete** button, `⌘⌫` / `Delete`, a photo's right-click menu,
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
then **Album** — both of which *narrow* 53,000 photos to something you would
actually look at — and then **Sort** last, pushed to the far right, because it is
the one control that changes no membership. It only reorders what is already on
screen, so it is the final decision about how to walk the result.

### The grid

A tile is a photograph and a score, and nothing else. No caption: not the date,
not the album, not a row of badges underneath. Hovering a tile names all three,
the lightbox shows them, and the tile's accessible name spells them out for a
screen reader — but the grid itself stays a contact sheet you can actually scan.

Tiles are **1px apart**, with 1px around the grid, so the photographs run together
the way they do in Photos. Every tile is a **square** and each photograph is
cropped to fill it: a square is the only shape that makes a grid of 53,000 of
them uniform, and uniformity is what makes it scannable.

One thing is drawn *on* the photo rather than beside it, because it changes what an
action **does**: a **♥** for a favourite, which is also the button that sets it.
Protection from deletion rides on the same glyph — while **Protect Favorites** is on,
a heart means the photo is excluded from bulk deletion — and the tooltip and the
tile's accessible name both say so.

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
- **⌘⌫** or **Delete**, which means the same thing;
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

**On by default.** While it is on, favourites are shown, marked as protected, and
**excluded server-side** from every bulk selection and deletion. Turning it off
is an explicit, deliberate action, it is remembered, and the interface warns you
when you do it.

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
- Verified at runtime: the process holds exactly one socket, `127.0.0.1:8765`.
  There are no outbound connections.
- The only authenticated network access is the one you opt into: PhotoKit
  fetching an iCloud-stored original (see below).

## iCloud behaviour

By default **"Download from iCloud when required" is off**, so a first run never
silently pulls down an entire optimized library.

- Assets whose pixels are not on this Mac are marked *not on this Mac*, counted
  separately from failures, and left alone. They are not errors and are not
  retried.
- **Thumbnails never fetch from iCloud**, regardless of this setting — scrolling
  past thousands of photos must not trigger thousands of downloads. Such tiles
  show an "In iCloud" placeholder.
- Turning the option on re-queues everything that was skipped and lets analysis
  and lightbox previews fetch originals.

On a typical optimised library a large share of assets are cloud-only: on the
machine this was developed against, **15,760 of 53,273** stills were not local.

## Cache and logs

| What | Where |
|---|---|
| Score cache | `~/Library/Application Support/PhotoCleaner/cache.sqlite` (plus `-wal`/`-shm`) |
| Preferences | `~/Library/Application Support/PhotoCleaner/settings.json` |
| Log | `~/Library/Logs/PhotoCleaner/PhotoCleaner.log` (rotates at 5 MB) |

The cache is a plain SQLite database — no server, no external dependency. Roughly
**15 MB for 53,000 assets** (14.4 MB of database plus the WAL and shared-memory
files); the live figure is `cacheBytes` in `GET /api/status`. Scores survive
restarts and completed assets are never re-scored; only new, edited or
upgraded-analyser assets are queued.

### Remove everything PhotoCleaner stores

```sh
rm -rf ~/Library/Application\ Support/PhotoCleaner ~/Library/Logs/PhotoCleaner
```

That is the complete list: the score cache and preferences live in Application
Support, and the log (with its rotated `PhotoCleaner.log.1`) lives in Logs.
Nothing else is written — no `UserDefaults`, no `~/Library/Caches`, no
`~/Library/Preferences` entry. Then delete `dist/` to remove the built app. Your
Photos library is untouched — PhotoCleaner adds nothing to it except the
deletions you perform.

Deleting the cache is safe but not free: the next launch re-scores the whole
library from scratch, exactly as a first run does.

## Performance

Measured on an M3 with a 53,273-photo library, concurrency 4, 1024 px analysis
inputs:

| Metric | Value |
|---|---|
| First full analysis | 53,273 photos in **2 min 27 s** (147 s, measured); ~240 scored/s, ~360 photos/s once the iCloud-only skips are counted |
| Resident memory | ~180 MB, flat in library size (assets are never held in memory) |
| Cache size | ~15 MB for 53k assets |
| 60 cold grid thumbnails | 1.4 s sequentially (~23 ms each) |
| CPU | ~3% — inference runs on the Neural Engine |

The 147 s comes straight from the log — `analyzing with concurrency 4 …` to
`analysis run finished` on the first launch — and it resolved **every** photo:
37,513 scored with the aesthetics model, 15,760 skipped because their pixels are
iCloud-only, none failed.

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
GET  /api/status                  library + analysis status (also pushed over SSE)
GET  /api/photos                  ?lo&hi&sort&favorites&album&limit&cursor&offset
GET  /api/timeline/around         ?id={anchor}&limit — one page either side of a photo
GET  /api/timeline/page           ?direction=older|newer&cursor&limit — All Photos paging
GET  /api/events                  Server-Sent Events; event: status
GET  /api/photo/{id}              one asset's metadata
GET  /api/photo/{id}/thumbnail    ?size=128|256|384|512
GET  /api/photo/{id}/preview      ?size=512…4096 (degrades to the best local rendition)
GET  /api/photo/{id}/similar      the Similar Group this photo is in — {groupId?, totalCount, analyzed}
GET  /api/groups                  ?order&limit&offset&album — every group, largest first
GET  /api/group                   ?id&order&album — one group, its members in the requested order
POST /api/groups/rebuild          group the library again
POST /api/selection/preview       resolve a selection without changing anything
POST /api/delete                  delete through PhotoKit
POST /api/settings                {downloadFromICloud?, protectFavorites?, concurrency?}
POST /api/analysis/retry          re-queue failed / skipped assets
POST /api/library/rescan          re-read the library and reconcile
```

`sort` ∈ `score_asc` (default) `| score_desc | date_desc | date_asc`;
`favorites` ∈ `include | exclude | only`.
`album` is `all` (default) `| none` (in no album) `| an album identifier`, and
means the same thing on `/api/photos`, `/api/groups` and `/api/group` — see
**Similar Groups** below for what it does to a group.
Asset identifiers contain `/`, so URL-encode them (`…%2FL0%2F001`); the server
also accepts unencoded slashes.

The two `/api/timeline/*` routes are read-only and take no body. They order by
**date alone** — the score is used only as the widest bound the cache can express,
never as an ordering key — and they deliberately ignore `lo`, `hi` and `favorites`,
so the All Photos window cannot be narrowed by a filter. Both anchor
their keyset on the photo's own `(date, id)`, so cost is independent of library
size and of the photo's age. `older` is descending from the anchor; `newer` is
ascending from it (nearest first), so a client displays newest-first by reversing.

Optional fields are **omitted**, not sent as `null`: the encoder drops nil
optionals, so `nextCursor`, `bounds.min`, `bounds.max`, `score.min`,
`score.max`, `analysis.etaSeconds`, `analysis.lastError`, `analysis.startedAt`
and `PhotoRow.date` may be missing from a response entirely. A client
must treat an absent key and an explicit `null` identically.

## Source layout

```
Sources/PhotoCleaner/
  main.swift                entry point; macOS 15 guard
  App/PhotoCleanerApp.swift launch sequence, banner, signals
  App/Presentation.swift    window / browser / headless, shutdown relay
  App/AppWindow.swift       NSWindow + WKWebView, navigation policy
  App/AppDelegate.swift     NSApplication lifecycle, menu, terminate handshake
  App/MainMenu.swift        the menu bar
  Support/                  paths, logging, preferences, SSE fan-out
  Model/Records.swift       asset/filter/sort/cursor types
  Library/PhotoLibrary.swift    all PhotoKit access (auth, enumerate, images, delete)
  Analysis/VisionAnalyzer.swift Apple's aesthetics, FeaturePrint and face requests
  Analysis/CacheStore.swift     SQLite actor: schema, reconciliation, queries
  Analysis/AnalysisEngine.swift scan + bounded analysis run loop, progress
  Analysis/SimilarGroups.swift  the group builder, face aggregation, Best Shot ranker
  Analysis/SimilarGroupEngine.swift  the background grouping pass and Tier 3 faces
  Analysis/SignalCompression.swift    LZFSE + Codable for the cached Vision payloads
  HTTP/                     Network.framework server, router, API
  Web/                      embedded-asset accessor + generated file
web/                        index.html, app.css, app.js (the editable UI source)
tools/embed-web.swift       folds web/ into the executable
tools/make-icon.swift       draws AppIcon.icns at build time
docs/ARCHITECTURE.md        the engineering record: measurements, invariants, limits
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
single photo is not a result.

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

`overallScore` is measured over −0.9959…+1.0000 on a real library and face capture
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
a 53,177-photo library:

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

A FeaturePrint is 768 floats: 3,072 B raw, 4,351 B as JSON. LZFSE brings that to
about 2.7 KB, so a 53k library costs roughly **144 MB** of extra cache — by far the
largest thing in it, against 15 MB before. It is compressed because
`FeaturePrintObservation` cannot be rebuilt from its raw payload through any public
API: its `Codable` conformance is the only route in, and that round trip was
verified bit-exact (worst distance error `0.0` across 400 pairs).

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
- Video support (enumeration is media-type parameterised; only stills are scored).

The test for any of these is the same: does it materially improve either same-shot
grouping or within-group ordering?

The same reasoning rules out the larger features: no threshold that deletes anything
on its own, no way to re-score the whole library, and no face identity recognition.

## Contributing

Issues and pull requests are welcome. Two things make this project unusual:

- **There is no package manager.** SwiftPM does not work on the target machine, so
  `build.sh` and `run-tests.sh` drive `swiftc` directly and there is no
  `Package.swift`. Do not add one.
- **Please add a test with any behavioural change, and prove it can fail.** Revert
  the fix in a scratch tree and watch the new case go red. A test that has never
  failed is not evidence of anything.

`./run-tests.sh` needs no Photos library and no network, and `./smoke-test.sh` audits
the build and the filesystem read-only. Both run in CI on every push.

## License

MIT — see [LICENSE](LICENSE).

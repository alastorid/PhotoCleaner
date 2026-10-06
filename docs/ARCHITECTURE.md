# Architecture

The engineering record for PhotoCleaner: how it is put together, the measurements
the design rests on, and the constraints that look like style but are not.

This is not a tutorial. For what the tool does and how to use it, read
[the README](../README.md). For the *why*, this file.

Two rules govern everything below:

1. **The AI sorts; the human deletes.** No score, ranking or group-relative value
   ever causes a deletion. There is deliberately no threshold that auto-deletes,
   and no way to trigger a full re-score.
2. **Every read and write goes through PhotoKit.** `Photos Library.photoslibrary`,
   its SQLite databases and the image files are never opened. PhotoCleaner has its
   own SQLite cache and treats Photos strictly through the public API.

---

## 1. Shape

```
Apple Photos ──PhotoKit──► PhotoLibrary ──► AnalysisEngine (4 bounded workers)
                                │                    │
                                │                    ├─► VisionAnalyzer (aesthetics
                                │                    │   + FeaturePrint + face quality)
                                │                    └─► CacheStore (SQLite actor)
                                │
                                ├─► AlbumIndexer ──► CacheStore
                                ├─► SimilarGroupEngine ──► CacheStore
                                │
                                └──► Router ──► HTTPServer (NWListener, 127.0.0.1)
                                                 EventBus (SSE) ──► AppWindow (WKWebView)
```

Three views sit over the same cache:

| View | Ordering | Served by |
|---|---|---|
| **Score grid** | by aesthetics score, filtered by the slider | `GET /api/photos` |
| **All Photos** | by date alone, day-groupped, anchored on one photo | `GET /api/timeline/around`, `GET /api/timeline/page` |
| **Similar Groups** | by within-group rank, filtered by the same album as the grid | `GET /api/groups`, `GET /api/group` |

All Photos is read-only, ignores every filter parameter on purpose — it is about
chronology, not ranking — and shares the selection with the grid rather than owning
one. Each restores the grid exactly where it was on Back.

### One group browser, two doorways

The Similar Groups view has two modes, distinguished by `state.groups.focused`: the
list of every group, or the one group a photo belongs to. **Show Similar Photos**,
on the tile context menu and the lightbox, is the second doorway. It resolves the
photo's group with `GET /api/photo/{id}/similar` and opens *this* browser with the
list taken away — same header, same sort control, same `buildGroup` — so the two
modes cannot disagree about what a group is or how it is ranked.

### The album filter reaches this view too

`state.album` is not the grid's private business, and the load-bearing reason is
that the alternative is a silent widening: a user who filtered to one album and
then opened Similar Groups would see *more* groups than the grid, with no visible
cause. `GET /api/groups` and `GET /api/group` therefore take `?album=` with the
grid's own wire values and the grid's own validation, and `AlbumSelection` grows one
`membershipClause(asset:albumParameter:)` that both the score filter and the group
queries build their predicate from — one definition of what each value means, so the
two cannot drift.

Two decisions, deliberately different:

- **A group qualifies if *any* member is in the album.** Requiring all of them
  would hide every group that straddles two albums, which is the case a user
  comparing albums most wants to see, and a burst is one cleanup decision
  regardless of how the user filed its frames. Implemented as `EXISTS` over the
  members primary key: one index probe per group, never per photo.
- **A strip shows only the album's members**, with `hiddenMemberCount` carrying
  what was left out. `memberCount` and `faceMemberCount` are counts *of what the
  response is about*, so a card cannot read "3 photos" above a strip of three next
  to a badge saying four of them have faces. The filtered counts are recomputed from
  `groupMembers(groupID:album:)` — read in full, not as a page, because a count
  taken from a truncated page is a count of the page.

`hiddenMemberCount` is **omitted** when no filter is applied, so an unfiltered
response is exactly what it always was and a client cannot mistake "no filter" for
"a filter that hid nothing".

A group with nothing in the album is served **200 with no items**, not a 404: the
group exists and is not being retired, and "this group has no photos in *Abao*" is
not "unknown group". The client distinguishes the two in `loadGroups`.

`selectAlbum` calls `resetGroupsWindow()` when the view is open. The offsets
(`startOffset`/`endOffset`) name a position inside one result set, so they are reset
with the generation bump for the same reason the grid drops its keyset cursor: an
in-flight page for the previous album would otherwise splice itself into the new
list. An album tag on a photo no longer closes the view — it re-filters it in place,
because leaving would throw away the group the user was reading to reach a filter
they could equally have applied from the chips.

`GET /api/photo/{id}/similar` is deliberately a lookup rather than a search. It
reads `similar_group_members` (already written by the last grouping pass) and
`asset_signals`, and answers `{groupId?, totalCount, analyzed}`. No image is decoded,
no FeaturePrint generated, no pair compared, no Vision request issued, and no
grouping pass started — a right-click costs two indexed reads and a navigation.

Two properties are load-bearing rather than incidental:

- **It reads membership, not the group list.** A list is a presentation with rules
  of its own and may omit groups that offer nothing to clean up; "which group is
  this photo in" is a property of the photo. Keeping them apart is what lets a group
  of three with two protected favourites open from any of its three members, all
  three intact.
- **`analyzed` is reported even when `groupId` is absent.** "No similar photos" and
  "analysis has not reached this photo" are both an absent group and they are
  opposite facts. Collapsing them would tell a user their photo is unique when
  nothing has compared it to anything yet. Neither state creates a group of one.

The originating photo is marked with `.group-cell.origin` and scrolled into view,
and it stays where the sort put it — a marker that reordered the strip would be
making the ranking a lie. It is emphatically not a selection: `.tile.selected` is
what marks a photo queued for deletion, and nothing in this path touches it.

Back returns to whichever view was underneath, recorded in `state.groups.returnView`
(`grid` / `allPhotos` / `groups`) rather than assumed to be the grid. All Photos is
cheap to return to because its rows and DOM are left untouched while the group view
is open, so Back unhides the window instead of re-fetching around the same anchor.

### Identifier-driven, always

`PHAsset` is not `Sendable` and does not cross a concurrency domain. Only
`localIdentifier` strings do; the asset is re-fetched per request. This is what
keeps resident memory flat in library size (~180 MB against a 53k library, measured)
rather than proportional to it.

### Concurrency

`AnalysisEngine` runs a fixed number of workers (default 4). Each worker claims
**its own** batch rather than sharing a refill buffer — a shared buffer lets two
concurrent refills overwrite each other's claimed batch and strands assets in the
`analyzing` state forever.

---

## 2. The environment this was measured on

These are measurements, not assumptions. Several are counter-intuitive enough to be
re-derived wrongly.

| Fact | Value |
|---|---|
| Machine | macOS 26.5.1 (build 25F80), Apple M3, arm64 |
| Toolchain | Swift 6.3.2, **Command Line Tools only** — no Xcode |
| **SwiftPM does not work here** | `swift package dump-package` fails to link `libPackageDescription` even for a three-line manifest. **There is no `Package.swift`, deliberately.** `build.sh` calls `swiftc` directly. |
| Library | 53,177 stills, 1,953 videos (videos are never scored), 107 favourites |
| **iCloud-only share** | **15,784 of 53,177 (~30%)** are not on this Mac. Normal for an optimised library, not a failure. |
| **Score range** | observed **−0.9476 … +1.0000** — *not* 0…1 |
| Analysis input | 1024 px longest edge. 256 px drifts up to **0.135**; 512 / 1024 / 2048 agree within **0.02**. |
| Throughput | whole library in **2 min 27 s** (147 s, from the log), concurrency 4 — ~240 genuinely scored/s, ~360 photos/s once cloud-only skips are counted |
| CPU | ~3%; inference runs on the Neural Engine |
| Cache, aesthetics only | ~15 MB for 53k assets including `-wal`/`-shm` |
| Cache, with FeaturePrints | **~175 MB** — vectors are ~2.7 KB each and are by far the largest thing in it |

**Why 1024 px.** It is the cheapest point on the measured plateau: about 4 MB of
RGBA per in-flight image and no full-resolution HEIC/RAW decode. Below it the score
drifts; above it nothing is gained.

**Photos authorization.** A directly-launched binary runs in a shell that is already
TCC-authorized and enumerates the library with no prompt. Launching through `open`
attributes the prompt to the app bundle instead, and blocks on a dialog. That is why
`--no-browser` and `--browser` never initialise AppKit: they are the paths that stay
usable over SSH and from `launchd`.

### API signatures and behaviours that bite

| | |
|---|---|
| `PHAsset.mediaSubtypes` | plural |
| `PHPhotosError.networkAccessRequired` | 3164 — the "pixels are not on this Mac" signal |
| **`.fastFormat` is useless for a grid tile** | it can return a 64×48 embedded thumbnail. `.highQualityFormat` + `resizeMode = .exact` is the only combination that reliably returns the requested size. |
| **Large renditions depend on what Photos holds locally** | a fixed 2048 px preview request fails with "stored in iCloud only" on a cloud-optimised asset even when 1024 px renders fine. Hence the descending size ladder in `PhotoLibrary.previewImage`. |

### Toolchain resolution

`build.sh` resolves `swift`/`swiftc` through `xcrun` and passes `-sdk` from the same
developer directory, on purpose. A compiler shadowed on `PATH` (Homebrew, Swift.org)
paired with the system SDK is the "this SDK is not supported by the compiler" failure.
`diagnose_swift_failure` recognises that signature — including the
`redefinition of module 'SwiftBridging'` that accompanies it — and prints the Command
Line Tools reinstall steps instead of a module dump.

---

## 3. Data model

One SQLite database, schema version 3, in Application Support. Migration is additive
and idempotent: every step is `IF NOT EXISTS`, nothing is dropped or rewritten, and
no existing table's shape changes, so an older cache upgrades in place.

| Table | Holds |
|---|---|
| `assets` | one row per asset: dates, dimensions, favourite, screenshot flag, aesthetics score, analysis state, attempts, last error, `scored_at`, analyzer version |
| `asset_signals` | one row per (asset, signal kind) — FeaturePrint and per-face capture quality, LZFSE-compressed |
| `albums` / `asset_albums` | user-album membership, many-to-many. `asset_albums`' primary key *is* the index for the filter's correlated `EXISTS`, and it makes duplicate membership impossible. Foreign keys cascade, so a deletion takes its album rows with it. |
| `similar_groups` / `similar_group_members` | materialised groups plus the settings they were built under, so "stale" can be told from "built with different rules" |
| `featureprint_queue` | scored assets with no vector yet — see §5.3 |

Groups are **materialised, not computed per request**: a rebuild walks the
capture-time neighbourhood (~3.9M distance comparisons for 53k assets), which is far
too much for a request handler. A rebuild writes; browsing reads.

Inspect the cache read-only, never write to it:

```sh
sqlite3 -readonly ~/Library/Application\ Support/PhotoCleaner/cache.sqlite \
  "SELECT analysis_state, COUNT(*) FROM assets GROUP BY analysis_state;"
```

A healthy idle library is `pending` and `analyzing` at 0, `phase: "up_to_date"`, and
`analyzed + failed + unavailable == total`. A large `unavailable` is normal for an
iCloud-optimised library.

---

## 4. HTTP

Loopback only. The listener binds `127.0.0.1` *and* rejects non-local peers, so the
service is never reachable from the LAN. `lsof` must never show `*:8765`.

```
GET  /                        GET  /api/photo/{id}/thumbnail   ?size=128|256|384|512
GET  /api/status              GET  /api/photo/{id}/preview     ?size=512…4096
GET  /api/photos              GET  /api/photo/{id}/similar     → {groupId?, totalCount, analyzed}
GET  /api/albums              POST /api/delete
GET  /api/albums/index        POST /api/favorites    {ids, favorite}
GET  /api/groups              POST /api/photos/reveal {id}
GET  /api/group               POST /api/groups/rebuild
GET  /api/events  (SSE)       POST /api/selection/preview
GET  /api/timeline/around     POST /api/settings
GET  /api/timeline/page       POST /api/analysis/retry
                               POST /api/library/rescan
```

- Every mutating route is **POST-only** and same-origin gated.
- Identifiers from the browser are **validated against the cache** before they can
  reach PhotoKit, so a stray request cannot name an arbitrary asset.
- `/api/delete` accepts an optional `confirmToken`: the fingerprint of the set the
  user reviewed. When one is presented it must still match the set that resolved, or
  the deletion is refused — review and deletion are two requests, and a rescan in
  between must not turn an agreed deletion into a different one. When it is absent
  the request is honoured, because the token is a *staleness* check on a set the user
  already saw, not the authorisation itself. Authorisation is the server-side
  favourite resolution below plus the same-origin gate; inventing a mandatory token
  would move the safety property into a value the browser controls.
- Asset identifiers contain `/`; clients must `encodeURIComponent`.
- Optional fields are **omitted**, never sent as `null`. A client must treat an absent
  key and an explicit `null` identically.
- **Slider bounds are data-derived**: `lo`/`hi` default to `MIN`/`MAX(aesthetics_score)`
  in the cache. The score is never normalised, clamped or assumed to be 0…1.
- Pagination is keyset, and `CacheStore.keysetClause` must stay in step with
  `SortOrder.orderByClause` — direction, tie-break direction and null handling are one
  invariant expressed in two places. Change one without the other and pagination
  silently skips rows.

---

## 5. Analysis

`VisionAnalyzer` issues Apple's `CalculateImageAestheticsScoresRequest` and unwraps
it. Nothing else is ever substituted for it, and the score range is taken as it comes
back.

### 5.1 The state machine

`pending → analyzing → done | unavailable | failed`. `unavailable` means the pixels
are not on this Mac; it is **not** an error and is not retried unless the user turns
on iCloud downloads. Completed assets are never re-scored: an asset keeps its score
unless its modification date or analyzer version changed.

### 5.2 Progress reporting is skip-inclusive

`currentRate()` counts a photo as processed when it is *skipped* for being iCloud-only
just as when it is scored. So `rate` and `etaSeconds` overstate throughput and
understate remaining time by roughly the cloud-only share. They must never be quoted
as inference throughput.

### 5.3 The FeaturePrint backfill

`upsert` deliberately keeps a `done` asset `done` when its modification date and
analyzer version are unchanged. A library scored by an earlier build would therefore
never gain a vector, and Similar Groups would be silently empty for exactly the users
who already have a cache.

Re-scoring instead would work but throws away good scores, and `upsert` nulls
`aesthetics_score` on requeue — so every photo would vanish from the grid for the
length of a multi-minute pass. Hence `featureprint_queue`: scored assets with no
vector, **claimed by deletion** (a crash loses the claim rather than leaving a
placeholder that would never be filled), and drained only once the scoring queue is
empty, so a first run spends its time on unscored photos first.

That queue deliberately skips the state machine. `recordFailure` would park an asset
whose analysis is already complete, and `releaseClaims` would look for an `analyzing`
row that does not exist.

---

## 6. Similar Groups

Photos that are alternate captures of approximately the same shot — the frames of a
burst, the takes of a portrait — grouped so the best one can be picked.

Two Apple Vision requests answer two **separate** questions, and the code keeps them
apart:

```
  GROUPING    FeaturePrint distance, restricted to a capture-time window
  RANKING     aesthetics, and face capture quality where faces exist
```

A FeaturePrint answers "do these look alike enough to be alternatives?". It never
answers "which is better", so its distance never enters a quality score. The two live
in separate types (`GroupingCandidate` vs `RankingInput`) precisely so nothing can
combine them — they are not on a common scale.

### 6.1 The threshold, measured

Measured against **genuine bursts** — runs of consecutive frames ≤2 s apart — not
against "everything within the window". That distinction is the whole measurement: a
120 s window on a real library holds up to 1,499 photos, so a threshold tuned on it
would be meaningless.

| pair kind | n | min | p50 | p90 | max |
|---|---|---|---|---|---|
| same burst | 28 | 0.020 | 0.054 | 0.282 | 0.535 |
| other bursts | 437 | 0.472 | 0.990 | 1.195 | 1.451 |

At **0.35**: 93% same-burst recall with **zero** cross-burst merges. At 0.55 recall
reaches 100% but 6 wrong merges appear. The distributions genuinely overlap in
[0.47, 0.53] — no threshold is exact. 0.35 is the default because a missed merge
costs one manual sort, while a false merge silently gathers unrelated photos.

Supporting measurements:

| | |
|---|---|
| FeaturePrint revision | `.revision2` is the only one the macOS 15 Swift API exposes (revision 1 is ObjC-only) |
| FeaturePrint size | 768 floats · 3,072 B raw · 4,351 B JSON · ~2,708 B LZFSE |
| Codable round trip | **bit-exact** — worst distance error `0.0` over 400 pairs |
| Raw payload | **not reconstructible** through any public API, so JSON is the only persistable form |
| Neighbours in a 120 s window | median 16, p90 177, **max 939** |
| Bursts on this library | 1,183 of ≥3 frames; size p50 6, p90 56, **max 1,253**; span p50 3 s, max 167 s |
| Cost | aesthetics + FeaturePrint together 7.2 ms, against 5.0 ms for aesthetics alone, at 1024 px |
| Face capture quality | 7.1 ms per image at 1024 px |

**Capture time is a weak restriction.** With a p90 of 177 and a max of 939
neighbours, chaining at a permissive threshold fuses a whole event into one unusable
group. Hence `maximumGroupSize`, and hence the chronological split into contiguous
chunks.

### 6.2 Best Shot is a rank, not a formula

`overallScore` is not 0…1 and face capture quality is 0…1. A weighted sum like
`aesthetics * 0.6 + faceQuality * 0.25` asserts a relationship between two
instruments that measure different things in different units. So each signal is
reduced to its **rank within the group** — best member 1.0, worst 0.0 — and the ranks
are blended. Rank is unit-free, so the blend means what it says.

The signals genuinely disagree, which is the justification for having two. One
measured burst:

| frame | aesthetics | face capture quality |
|---|---|---|
| 1 | +0.7515 | 0.585 |
| 2 | +0.7061 | 0.437 |
| 3 | +0.7021 | 0.605 |

Aesthetics puts frame 1 first; face capture quality puts it second.

**Face aggregation is a minimum over significant faces, not a mean:**

| | person 1 | person 2 | person 3 |
|---|---|---|---|
| photo A | .91 | .88 | **.24** |
| photo B | .85 | .82 | .80 |

A mean rates A at .68 and B at .82 — "A is a bit worse". The truth is that one person
was captured badly in A while all three were captured evenly in B. Faces below 1% of
the frame are excluded; measured face areas run 0.0017…0.90, so an unfiltered mean
is dominated by whichever incidental background face Vision happened to find.

`faceWeight` (default 0.5) is the only tunable, and it applies solely to photos that
have a face observation — a group with no faces ranks on aesthetics alone.

**Face capture quality is capture quality: lighting, sharpness, blur, positioning.**
Never label it a beauty, attractiveness or hotness score, in code, in the UI, or in a
commit message.

### 6.3 Absence is meaningful

A missing `faceCaptureQuality` means "no face found" or "not analysed yet". A missing
`bestShot` means "this is not a Best Shot ordering". Never substitute `0` — a zero
reads as a measured worst and makes an un-analysed photo look like a bad one.

**Best Shot must not delete anything.** No code path reads it. It is an ordering
within a group, nothing more, and no group-relative value may ever reach the delete
route.

### 6.4 Cost, and the lack of eviction

A FeaturePrint is LZFSE'd to ~2.7 KB, so a 53k library costs roughly **144 MB** of
extra cache — against 15 MB before. It is the largest thing in the cache and there is
**no eviction**: an asset that loses its vector gets it back on the next pass, but
nothing prunes one that is no longer needed.

---

## 7. The window

The default presentation is a native `NSWindow` hosting a `WKWebView` pointed at the
same loopback server the browser used. The server is unchanged; only the host is.
`--browser` and `--no-browser` remain available and behave as they always did.

Each of these is load-bearing:

- **The window loads `http://127.0.0.1:<port>`; it does not serve the UI through a
  `WKURLSchemeHandler`.** `EventSource` does not work on a custom scheme, and the live
  progress read-out is the point of the window. WebKit renders the same loopback app
  the browser was rendering.
- **That makes App Transport Security apply.** A page typed into Safari is exempt; a
  hosted web view is not. Hence `NSAppTransportSecurity`/`NSAllowsLocalNetworking` in
  `Info.plist` — the narrow key, loopback only, never `NSAllowsArbitraryLoads`.
  Remove it and the window comes up blank.
- **The web view must stay non-persistent.** `WKWebsiteDataStore.nonPersistent()` is
  what keeps `~/Library/WebKit` and `~/Library/Cookies` non-existent, which
  `smoke-test.sh` asserts. The UI stores nothing client-side, so it costs nothing.
  (`WKWebViewConfiguration.urlCache` is iOS-only — there is no macOS API to disable
  the shared URL cache, so do not try to add one.)
- **Only the windowed presentation may touch AppKit.** The other two keep the
  top-level-`await` shape, which is the only reason they still start on a machine with
  no window server.
- **`WKUIDelegate` dialogs are implemented on purpose.** WebKit silently never shows
  `alert`/`confirm`/`prompt` for a hosted view, and a confirmation that never appears
  is indistinguishable from one that was skipped. The UI uses its own modal today, but
  that is a coincidence, not a reason to delete them.
- **`applicationShouldTerminate` returns `.terminateLater`.** ⌘Q, the Dock's Quit and
  the close button all converge on one graceful shutdown whose reply comes from the
  app's exit path. Calling `exit` from the delegate instead skips flushing the cache.
- **A second launch raises the running window** via `NSRunningApplication.activate`,
  falling back to the browser when there is no window. It deliberately does *not*
  reload, which would discard the user's filter and selection.
- **No private API.** `WKWebView.inspector` does not exist on macOS; the Web Inspector
  is opted into with `PHOTOCLEANER_WEB_INSPECTOR=1`, which registers
  `WebKitDeveloperExtras` in the *registration* domain so nothing is written to disk.
- **The icon is drawn by `tools/make-icon.swift`, not checked in.** Its gradient
  matches `.app-mark` in `web/app.css`; keep them in step.

---

## 8. Constraints that look like style but are not

Each of these was established by measurement or by a real defect. Undoing one is a
bug, not a cleanup.

- **Never touch `Photos Library.photoslibrary`,** its databases, or any image file.
- **Never normalise, clamp or hard-code the score range.** `overallScore` is not
  0…1; the slider's limits come from `MIN`/`MAX(aesthetics_score)`.
- **A FeaturePrint distance must never enter a quality score.** See §6.
- **Face capture quality is capture quality, not attractiveness.** See §6.2.
- **Best Shot must not delete anything.** See §6.3.
- **Group sizes are bounded** — `maximumGroupSize` and the chronological split exist
  because a 120 s window on a real library holds 1,499 photos.
- **Favourite protection is enforced server-side,** in `Router.resolveSelection`, from
  stored `favorite` flags — never from what the browser claims. It is **fail-closed**:
  if the favourite check itself errors, the selection resolves to *nothing* rather
  than to "no favourites". `PhotoLibrary.delete` re-reads `asset.isFavorite` live at
  the point of destruction, because the cached flag is only as fresh as the last scan.
- **The Photos authorization gate covers the routes that act,** not the ones that
  report. Deletion, favourites, reveal, album reindex and the group routes refuse
  with 403 when access is absent; `/api/status`, `/api/settings` and the
  cache-backed reads stay reachable, because an app that cannot show why it is
  refusing cannot be recovered from. The status is read *per request* — latching it
  at startup would leave a user who grants access mid-session permanently blocked,
  with nothing in the UI to suggest a restart.
- **`withCheckedThrowingContinuation` around `PHImageManager` must stay single-shot.**
  PhotoKit can invoke the handler more than once (degraded then final, or image then
  error) and a second `resume` traps. That is what `ResumeBox` is for; the same guard
  protects `performChanges`.
- **`OSAllocatedUnfairLock.withLock` passes an `inout` reference — mutate it in
  place.** Mutating a copy writes the right value to disk while in-memory state stays
  stale for the life of the process.
- **A 413 must never be spliced into an already-streaming SSE response.** Every error
  path consults the single-response latch before writing.
- **A missing `ids` key is a 400, not an empty selection.** An explicit `[]` is
  legitimate — that is how the UI clears a selection — but "delete these four" with a
  typo'd key must not resolve to deleting nothing having asked for nothing.
- **`CacheStore.keysetClause` and `SortOrder.orderByClause` must stay in step.** See §4.
- **`node --check` parses; it does not resolve.** It cannot see a call to a function
  that does not exist, so grep for the callee. A `$('id')` with no matching element in
  `index.html` throws only on the branch that needs it, which is why the two files are
  cross-checked mechanically.
- **A fresh count must never sit beside a stale token.** The selection holds the
  `confirmToken` from the `/api/selection/preview` that produced the count printed on the
  Delete button, and presents it on the deletion. With no staged list in between, the
  window is short — but it is the only thing standing between the count the user read
  and the set that is destroyed, so wherever a count is re-read (favourite protection
  toggled, a 409 refusal) the token has to be replaced in the same moment. A fresh
  number beside a stale token is a deletion that refuses itself; a stale number beside a
  fresh token is the failure this exists to prevent.
- **Delete is the one control, and its guard is the resolved count.** `canDeleteSelection`
  is read by the label, by the enabled state and by the keyboard alike, so the three
  cannot disagree. It requires `selection.resolved > 0`, which means the button is dead
  until the server has said how many photos a press would destroy — a deletion of
  unknown size is refused rather than guessed at.

---

## 9. Deliberate non-goals

- No "delete everything below score X". Ever.
- No way to re-score the whole library. `analysisPixelSize` is exposed read-only over
  HTTP precisely so it cannot trigger a full run.
- No writing to the Photos library other than deletions you ask for. Deletion is one
  step: the Delete button, `⌘⌫`, a tile menu's item and the preview's own button all
  build a *spec* and send it to `/api/delete` through one function. Nothing else in the
  app calls that route. There is no staged list and no undo — the deletion goes to
  Recently Deleted, and the server refuses it outright if the set no longer resolves to
  the fingerprint the count was printed with.
- No video scoring — enumeration is media-type parameterised, so the 1,953 videos sit
  unscored.
- No face identity recognition. Never, for any reason.

### Vision capabilities deliberately not used

These are real capabilities left out on purpose, because nothing demonstrated they
improve either same-shot grouping or within-group ordering.

| not used | why it would help, and why not yet |
|---|---|
| image registration (translational, homographic) | a second-stage test for pairs already close in both time and distance, to tell "same shot" from "merely similar scene". Only worth adding if grouping shows false merges. |
| saliency (attention / objectness) | compares *framing* between captures. Contextual only — never another score to add to the rank. |
| face landmarks | supporting information at most, and only for near-identical portrait frames. |
| lens-smudge detection | a technical capture penalty that could become a Best Shot adjustment. Must never affect grouping. |
| human/hand pose, animal recognition, OCR, foreground masks, object tracking, optical flow, trajectories, contours | nothing showed they improve grouping or ordering. |

The test for adding any of them: does it materially improve same-shot grouping or
within-group ordering? If neither, it does not belong.

---

## 10. Known limitations

- Ad-hoc signing means a rebuilt app may re-prompt for Photos permission. A Developer
  ID signature would keep the grant stable; ad-hoc is what a dependency-free local
  build can do.
- **The cache grows by ~144 MB** once FeaturePrints are computed, and there is **no
  eviction** (§6.4).
- The ~30% of the library that is cloud-only can be neither grouped nor
  face-analysed until iCloud downloads are enabled, so the group list covers a minority
  of the library by default. `GET /api/groups` reports `featurePrints` so this is
  visible rather than implied.
- Enabling iCloud downloads makes the first analysis much slower and pulls data from
  Apple's servers — by explicit user action only.
- Groups are built lazily on the first `GET /api/groups`, and that pass takes ~10 s on
  a 9-photo fixture and minutes on a real library. The view is answered from the last
  completed pass while it runs, so a first visit shows an empty list with "grouping" in
  the status line rather than blocking.
- **The FeaturePrint threshold and capture window are calibrated on one library.** They
  are settings precisely because that will not transfer: a photographer shooting tight
  bursts wants a narrow window, someone grouping a long event wants a wide one.
- The Best Shot weight (0.5) is the only *uncalibrated* number here. It was chosen as
  the value asserting no preference between two signals, not fitted against human
  judgement.
- `analysisConcurrency` changes take effect on the next run loop (rescan or relaunch).
- Progress read-out counts cloud-only skips as processed (§5.2).
- Preview quality degrades to the best locally-available rendition; the lightbox does
  not report which size it settled on.
- Deletion speed depends on iCloud. Removing cloud-only originals is slow and syncs to
  every device, and a large batch can make Photos show progress UI. This is an observed
  effect of the platform, not suppressible through any public API.
- A scan is not a consistent snapshot: the library can mutate mid-enumeration. That is
  handled, but not prevented.

---

## 11. How this is verified

There is no Xcode project and no test framework dependency — the suite is a plain
executable, because SwiftPM does not work here.

1. **`./run-tests.sh`** — the regression suite. Currently **210 assertions, 0 failing**
   (~6 s), covering selection resolution, the count contract, fail-closed favourites,
   keyset pagination over tied values, the analysis state machine, HTTP parsing and
   single-response latching, timeline ordering, confirm tokens, albums, similar groups,
   schema migration, the Photos authorization gate, and the window's launch-flag
   parsing, shutdown relay and navigation policy. It needs no Photos library and no
   network.
2. **`./build.sh`** — compiles with `-warnings-as-errors` and assembles the bundle.
3. **`./smoke-test.sh`** — audits the real cache and, importantly, **what the app has
   written outside Application Support and Logs**. The windowed app is allowed exactly
   one preferences key; anything else fails the run.
4. **Against the real library**, for anything structural that needs real PhotoKit or
   Vision behaviour.

Set `PHOTOCLEANER_SLOW_TESTS=1` to include the cases that wait on production
timeouts.

**A new test is only worth having once it has been seen to fail.** When changing
`CacheStore` pagination, `resolveSelection`, or the deletion path, prove the case is
load-bearing by reverting the guarantee in a scratch tree and watching it fail. Tests
that have never failed prove nothing.

---

## 12. Commands

```sh
./build.sh                       # compile + bundle + draw icon + ad-hoc sign
./run-tests.sh                   # full suite
./run-tests.sh --list            # how many cases are registered
./run-tests.sh --only groups     # one suite
./run-tests.sh --strict          # also fail on known-bug cases
./smoke-test.sh                  # real-cache and filesystem audit

./photo-cleaner                  # build if needed, start, show the window
./photo-cleaner --foreground     # logs to this terminal
./photo-cleaner --browser        # the default browser instead of the window
./photo-cleaner --no-browser     # no interface at all; just the server
./photo-cleaner --port 8766      # a different loopback port

lsof -nP -iTCP:8765 -sTCP:LISTEN # confirm the loopback-only binding
rm -rf ~/Library/Application\ Support/PhotoCleaner ~/Library/Logs/PhotoCleaner
```
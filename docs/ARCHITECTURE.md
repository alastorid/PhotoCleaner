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
                              │  │                │
                              │  │                ├─► VisionAnalyzer (aesthetics
                              │  │                │   + FeaturePrint + face quality)
                              │  │                └─► CacheStore (SQLite actor)
                              │  │
                              │  └─► VideoLibrary (clips: frames, export, playback)
                              │
                              ├─► AlbumIndexer ──► CacheStore
                              ├─► SimilarGroupEngine ──► CacheStore
                              │
                              └──► Router ──► HTTPServer (NWListener, 127.0.0.1)
                                              EventBus (SSE) ──► AppWindow (WKWebView)
                                                                    │
                                                              UpdateIndicator
                                                                    │
                                               Updater ──► release feed ──► UpdateInstaller
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

The **media** dimension travels with it, and the client resets both windows when it
changes for the same reason it resets on album: a cursor and a pair of offsets name
a position inside one result set, so a page still in flight for the previous filter
must be discarded rather than appended to the new one. What it *does* to a group
list is worth being explicit about: a clip never has a FeaturePrint and so is never
a member, so `media=images` and `media=all` return the same groups and
`media=videos` returns none. `media` is accepted rather than refused because the
client sends the grid's whole filter as it stands, and refusing the dimension would
be a worse answer than answering it honestly.

Changing the media filter also makes a "matching" selection stale, exactly as an
album change does: `sameFilter` reads `media`, and deletion is blocked until the
user re-snapshots or clears it. An explicit id selection is unaffected — those are
assets the reader pointed at.

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
| Library | 52,661 stills, 113 favourites, in the cache this run measured. Enumeration now covers clips as well, so `library.total` is photos *and* videos and `library.videos` says how many of them are which. |
| **iCloud-only share** | **15,600 of 52,661 (~30%)** are not on this Mac. Normal for an optimised library, not a failure. |
| **Score range** | observed **−0.9399 … +1.0000** — *not* 0…1 |
| Analysis input | 1024 px longest edge, per frame. 256 px drifts up to **0.135**; 512 / 1024 / 2048 agree within **0.02**. |
| Throughput | whole library in **2 min 27 s** (147 s, from the log), concurrency 4 — ~250 genuinely scored/s, ~360 photos/s once cloud-only skips are counted |
| CPU | ~3%; inference runs on the Neural Engine |
| Cache, asset rows and indexes | ~40 MB, `-wal`/`-shm` included |
| Cache, `asset_signals` | **~150 MB** — 37,056 compressed FeaturePrints at a measured 2,562 B each, plus face capture quality |

A library is not a constant: photos arrive and are deleted, so the counts above are
a snapshot of one library at one moment and the numbers are expected to drift. What
does not drift is the shape — roughly 30% of an optimised library is cloud-only,
and the minimum score is well below zero.

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

One SQLite database, schema version 5, in Application Support. Migration is
additive and idempotent: every step is `IF NOT EXISTS` or
`addColumnIfMissing`, nothing is dropped or rewritten, and no existing row changes
meaning, so an older cache upgrades in place.

| Table | Holds |
|---|---|
| `assets` | one row per asset: media type, dates, dimensions, favourite, screenshot flag, clip duration (`NULL` for a still), aesthetics score, analysis state, attempts, last error, `scored_at`, analyzer version |
| `asset_signals` | one row per (asset, signal kind) — FeaturePrint and per-face capture quality, zlib-compressed behind a one-byte codec marker |
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
GET  /app.css                 GET  /api/photo/{id}/preview     ?size=512…4096
GET  /app.js                  GET  /api/photo/{id}/similar     → {groupId?, totalCount, analyzed}
GET  /favicon.ico   (204)     GET  /api/photo/{id}/video       a byte range of the clip
                              POST /api/albums/index
GET  /api/status              POST /api/delete
GET  /api/photos              POST /api/favorites    {ids, favorite}
GET  /api/albums              POST /api/photos/reveal {id}
GET  /api/photo/{id}          POST /api/groups/rebuild
GET  /api/groups              POST /api/selection/preview
GET  /api/group               POST /api/settings
GET  /api/events  (SSE)       POST /api/analysis/retry
GET  /api/timeline/around     POST /api/library/rescan
GET  /api/timeline/page
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
- **Every JSON answer carries `Cache-Control: no-store`.** `no-cache` would still let
  the body be *stored* and only oblige a revalidation, which is the write this
  prevents. It is on the 404 too: a not-found is as much a live answer as a 200.
  `smoke-test.sh` fails the run if the URL cache ever holds a response.
- **Slider bounds are data-derived**: `lo`/`hi` default to `MIN`/`MAX(aesthetics_score)`
  in the cache. The score is never normalised, clamped or assumed to be 0…1.
- Pagination is keyset, and `CacheStore.keysetClause` must stay in step with
  `SortOrder.orderByClause` — direction, tie-break direction and null handling are one
  invariant expressed in two places. Change one without the other and pagination
  silently skips rows.
- **Every filter dimension is in the pagination fingerprint**, media included: a
  cursor issued under `media=images` replayed under `media=videos` would splice the
  two sets together, in a list whose positions no longer mean what they did.
- **`/api/photo/{id}/video` is the one route that answers 409.** A clip that exists
  but is iCloud-only is not a 404 — that would read as "this video is gone" and send
  the user looking for a file that is sitting in iCloud. It says which preference
  turns the answer from 409 into 200.
- **The media dimension is a closed set of literals, not placeholders.** `PhotoFilter`'s
  `whereSQLClause` has a fixed parameter budget (`?1`, `?2` the score bounds, `?3` the
  album, then keyset), so `media_type = 1` / `media_type = 2` are written into the
  SQL rather than bound. `claimJobs` takes the same shape as `IN (1, 2)` for the
  mirror-image reason: `!= 1` would start scoring an asset whose media type is
  `audio` or `unknown`, which this pass has no way to produce frames for.

---

## 5. Analysis

`VisionAnalyzer` issues Apple's `CalculateImageAestheticsScoresRequest` and unwraps
it. Nothing else is ever substituted for it, and the score range is taken as it comes
back.

**One frame or three.** `framesForAnalysis` returns a single still for a photo and up
to three frames for a clip, sampled at 10%, 50% and 90% of its duration. A frame that
fails is dropped rather than failing the asset — three samples become two, and two
become one, which `analyzeFrames` still scores and still logs. The alternative is a
second, video-only failure path in which a clip had to be guessed at, which is
exactly the "one bad moment aborts the pass" failure the shared path avoids.

**A clip's score is a median, and it has no vector.** `analyzeFrames` takes the median
of the per-frame scores and returns `nil` for the FeaturePrint whenever there was more
than one frame. Both facts are one function because "no vector for a clip" is a
property of what a clip *is*, not of which pass is running. A clip can be deleted,
filtered, sorted and previewed; it can never be a group member.

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

The window also has to *expire*. Throughput is measured over the completions of the
last 15 s, and when none of them are that recent the answer is **zero**, not the
average of the window that preceded the silence. Measured before the fix, on a pass
that had made no progress for four minutes: `rate` 0.54, `etaSeconds` 31,190. The
window was pruned only when a *new* sample arrived, so a stall had no new samples and
reported the last window forever. A client draws a countdown from that number, which
means a stopped pass looked healthy — the one read-out that exists to say otherwise.

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

### 5.4 No framework callback may hold a worker forever

Every wait on PhotoKit or AVFoundation in the analysis path is bounded by a
`CallbackDeadline`, and a request that goes unanswered is cancelled and reported as
`PhotoLibraryError.requestTimedOut` — a failure, with **no automatic retry**, re-queued
only by the user's **Retry**. Three waits, and they are the whole set: the image
request (`PhotoLibrary.requestImage`, 120 s), a clip's `AVAsset`
(`VideoLibrary.videoAsset`, 300 s, which may be a whole cloud download), and one
generated frame (`VideoLibrary.generateOneFrame`, 120 s).

The failure this prevents is not a slow asset, it is a stopped pass. Measured on a
54,614-asset library: with iCloud downloads on, `requestImage` left its handler
uncalled for **minutes** for one asset while the same asset answered in **3 ms** when
the request was not allowed to reach the network. An `await` on a handler that never
runs suspends its task with **no thread behind it** — nothing times out, nothing
logs, nothing recovers — and `analyze()` waits for all four workers. One such asset
parks a worker for the life of the process, the phase stays `analyzing`, and
`percent` (terminal rows over total) stops at whatever it had reached. A relaunch
reproduces it exactly, because `claimJobs` drains the queue by `creation_date DESC`
and claims the same assets at the same point. **A stall that a restart reproduces is
not a slow pass**, and it must never be diagnosed as one.

No automatic retry, and that is about *where* the retry lands. `recordFailure`'s
retry returns the row to `pending` with its original `creation_date`, and `claimJobs`
drains `pending` newest-first — so a timed-out asset comes back at the **front** of
the queue and the next worker to claim a batch waits out the whole deadline again.
Measured on the same library, with the retry in place: **eleven** such assets held
four workers for eighteen minutes and advanced the pass by two assets. Without it,
each costs one deadline, once, and the row is a visible failure with a Retry that
does not re-block anything. `recordFailure(retry: false)` is that switch, and
`framesForAnalysis` applies the same reasoning to a clip's three samples: an
unanswered `AVAsset` aborts the clip's remaining frames instead of waiting out the
same silence three times.

Two things are deliberately *not* done here. Apple's `AVAssetImageGenerator.image(at:)`
is not used, because a continuation the caller does not own cannot be cancelled or
resumed by anyone else; `VideoLibrary.generateOneFrame` drives
`generateCGImagesAsynchronously` so it can cancel with
`cancelAllCGImageGeneration()`. And the deadline answers *before* it cancels: `finish`
is the single-shot gate, so cancelling first would let the framework's own cancelled
callback win the race with `imageUnavailable` — and `unavailable` is the state that
is never retried, which is the wrong fate for an asset nothing was learned about.

`VideoStreamer.videoAsset` carries the same hazard — it is the same `requestAVAsset`
call, duplicated for fMP4 playback — and is *not* bounded. A clip whose request goes
unanswered parks an HTTP handler rather than an analysis worker, which is a stalled
player instead of a stalled pass.

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
| FeaturePrint size | 768 floats · 3,072 B raw · 4,351 B JSON · **2,562 B** zlib, measured across the 37,056 vectors in a real cache |
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

A FeaturePrint is zlib'd to a measured **2,562 B**, so the 37,056 vectors in a real
cache are **~90 MB** of it — against ~40 MB for the asset rows, album membership and
groups together. It is the largest thing in the cache and there is **no eviction**:
an asset that loses its vector gets it back on the next pass, but nothing prunes
one that is no longer needed.

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
- **The icon is drawn by `tools/make-icon.swift`, not checked in.** Its body
  gradient matches `.app-mark` in `web/app.css`; keep those two in step. It is
  deliberately **not** `--accent`: the icon is neutral grey while selection keeps
  a real hue, because a grey accent makes a selected tile look unselected and
  selection is this app's core action.

  The grey is a measured choice, not a preference. A neutral icon has no hue to
  separate itself from the desktop with, so the ramp has to clear the desktop's
  *luminance* instead — and because the whole icon sits on the wallpaper, that
  means **every pixel of the body against every wallpaper**, a min over both ramp
  ends and all of them. Pairing them light-end-on-light and dark-end-on-dark is
  the trap: it reports a graphite body as a comfortable pass (its dark end scores
  12.94:1 on a light desktop) while the light end is sitting at 1.09:1 on a dark
  one. That error is what `Tests/IconTests.swift` was first written with.

  Against that min, both obvious neutrals fail outright. Graphite
  `#4a4a4f` → `#232326` bottoms out at **1.09:1** — the dark end on `#1c1c1e`,
  where the edge vanishes. White `#fbfbfd` → `#dcdce1` reaches **1.00:1**, an
  exact match against the light grey desktop. The mid grey `#9a9aa0` → `#54545a`
  clears all six wallpapers at a worst corner of **1.85:1** (`#54545a` on
  `#2c2c2e`), which is what sets the 1.25 floor in the suite. Re-measure before
  moving it towards either end.

  The mark is a 3×3 contact sheet — the app's own grid — fading in reading order.
  What was measured about it, and what was not:

  * The grid resolves cleanly at **32px**, and keeps resolving with the tile gap
    tightened from 60 units to about 26. At 16px it is marginal at *any* gap in
    this range — three tile runs are only separable at a threshold within a few
    percent of the way up the tile-to-gap contrast. So the gap is not what makes
    the grid work; it is set wide because it looks right, and the suite pins the
    size at which the grid genuinely reads rather than pretending 16px is fine.
  * The opacity run ends at 0.46 rather than the 0.26 a steeper falloff looks
    better with at 512px. The measured reason is modest: at 32px the faintest
    tile's contrast against the gap beside it only moves from 1.41:1 to 1.25:1
    across that whole range, because tile and gap darken together. The floor in
    `Tests/IconTests.swift` is set to catch a tile disappearing altogether, not
    to police this particular number.

### The title-bar arc

The window carries one accessory view: `UpdateIndicatorController`, added at
construction as an `NSTitlebarAccessoryViewController`, which draws the updater's
state and posts a click back to `AppDelegate`. Several properties of it are
deliberate:

- **The window draws and starts nothing.** It holds no `Updater` and never touches
  the network. The one place in the app that can replace the running bundle is
  `PhotoCleanerApp`, which owns the process; a view controller that could start a
  download would be a second owner of that.
- **The arc is a control, and its title says what a click will do** — "Update to
  1.2.4…" when there is an update, "Check for Updates…" when there is not, and the
  phase while one is in flight. A fixed label next to a known version is a question
  the user has to answer mentally.
- **A click is not confirmed.** The affordance is labelled with what it does and
  the app replaces itself; a confirmation sheet on the app's own title bar would be
  a dialog it had already answered.
- **A failure is shown; success is not.** Success ends in the window being replaced,
  so an alert then would race the restart. A failure has to be loud, because an app
  that silently stays on the old version is worse than one that says why.
- **The flow is one actor.** `Updater` is an actor because the flow is a state
  machine with exactly one writer: a second check arriving mid-download must not
  start a second one. `Phase.isBusy` is what refuses it.
- **The session is ephemeral, with no cache and no cookie storage.** That is not
  tidiness — it is what keeps `smoke-test.sh`'s check that the URL cache holds no
  response true now that the app makes a request off the machine. A cached release
  feed would also mean a user on a plane could be told they were up to date for as
  long as the cache entry lived.

`UpdateTarget.plan` decides where the update goes *before* anything is downloaded,
and the install is verified twice: once on the copy staged inside Application
Support and once on the bundle that is actually installed afterwards, with the
outgoing bundle moved aside first so a failed swap rolls back rather than leaving no
app.

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
- **Favourite protection is not a setting.** `POST /api/settings` refuses
  `protectFavorites: false` with a 400 rather than quietly ignoring it — a stale
  client reporting success, with a checkbox drawn unchecked, is a false account of
  what will happen to favourites — and `SettingsSnapshot.init(from:)` does not decode
  the key at all, so a `settings.json` written by a build that had the switch still
  round-trips and still reads as protected. There is no undo for turning it off,
  which is why there is no turning it off. **The key stays in `CodingKeys` on
  purpose**, so the value is still written and a stale key in an old file is ignored
  rather than fatal; removing the entry as dead code would break the round trip.
- **Hiding a control is not the same as enforcing the behaviour behind it.** Removing
  the switch without touching the backend would have left every user who had turned
  it off with deletable favourites and no way to notice. The invariant has to be
  established on the side that decides, and only then is the UI free to stop offering
  it.
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
- **Every wait on a PhotoKit or AVFoundation callback in the analysis path stays
  bounded**, and the deadline answers before it cancels the request. PhotoKit is
  allowed to never call a handler, and an unbounded `await` on one suspends its task
  with no thread behind it — no timeout, no log, no recovery — which stops the whole
  pass at a percentage a relaunch reproduces. Four workers, one poison asset each.
  See §5.4.
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
  `web/index.html` throws only on the branch that needs it, which is why the two
  files are cross-checked mechanically.
- **A JS animation must be skippable, and its timing must be bounded.** Anything that
  moves an element is driven by `setTimeout` rather than by `transitionend`, because
  `prefers-reduced-motion` collapses transition durations to ~0 and under a headless
  DOM the events never fire at all. Every timer must have a cap, or a failed or silent
  async step leaves an element stranded on screen.
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
- **The preview overlay is `hidden` first, then `.is-open` — with a flush in
  between.** `display: none` cannot be transitioned and `[hidden]` wins with
  `!important`, so an animated overlay needs three states, not two. Setting
  `hidden = false` and adding `.is-open` in the same tick leaves the browser with no
  previous computed style to transition from and the backdrop arrives in one frame;
  reading `offsetWidth` between them is what gives it a `opacity: 0` to fade up from.
  Closing is the same walk in reverse, with `hidden` set only after the fade.
- **`.lightbox-stage` has a pinned height, not one fitted to the image.** The preview
  animation has to know where the photograph is going before the photograph arrives —
  the 2048px preview is still being fetched when the travel starts — so the box holding
  it must not resize itself on arrival and move its own destination out from under the
  animation. Anything that lets the stage grow with its content reintroduces a jump
  halfway through every open.
- **Whatever rendition is loaded, the still fills the stage's fitted box.**
  `#lightboxImage` is `width/height: 100%` with `object-fit: contain` — the geometry the
  travelling copy uses — and it is not cosmetic. The photograph on the stage starts as
  the *local* rendition (256px of it, §8) and sharpens in place, so an element sized by
  `max-width` alone draws that rendition at its own pixel size: paging to the next
  photograph reads as a small picture expanding, the frame is mostly the stage's dark
  panel until the original lands — which for a cloud-only photo can be minutes or
  never — and the hand-over from the travelling copy (identical bitmap, identical box)
  is a resize instead of a change of sharpness. Nothing in jsdom can see any of that:
  CSS layout does not exist there, so this one is a rule to keep, not a test to pass.
- **The still is held and revealed instantly; only a clip cross-fades.** Both edges of
  `lightbox-entering` matter for a photograph. Fading in leaves the destination-sized
  still half-visible underneath the copy still flying towards it, which is the two-copies
  failure the hold exists to prevent; fading out leaves the still and the copy both
  semi-transparent over the dark backdrop, and the frame measurably dims for the ~80ms
  they take to sum back to opaque (0.81 of the photograph at the darkest). A clip keeps
  the fade, because what arrives on top of its poster still is the video's own frame.
- **What travels is the thumbnail, never the preview.** The preview is a 2048px JPEG
  that has not been requested when Space is pressed; animating toward it would mean
  animating the absence of a bitmap. A copy of the already-decoded thumbnail makes the
  trip, positioned `fixed` in viewport coordinates so a resizing stage cannot drag it,
  and it is taken away once there is a picture underneath it — a still simply reveals
  one; only a clip cross-fades.
- **The hand-over waits for the travel *and* for a picture.** Crossing over while the
  thumbnail is still in flight puts the sharp photograph at full size with a blurred
  copy of itself sliding into the grid on top of it. A still reports that it has a
  picture from its own walk through the renditions of it (`renderLightboxStill`); a
  clip waits for `loadedmetadata`, bounded by `preload="metadata"` and therefore free
  of the body's bytes. The wait is not on a timer: a preview still coming down from
  iCloud leaves the local rendition the grid was already drawing on the stage, holding
  the travelling copy — which is a copy of that same bitmap — over a picture rather
  than over an absence.
- **The preview is filled from what this Mac already has, then from the original, and
  only then from a sentence.** `/api/photo/{id}/preview` asks PhotoKit for the
  *original*, which with "Download from iCloud when required" on is a request that
  waits for pixels to come down — seconds for a photo this Mac once held, and longer
  for one it never has. The grid tile beside it has been drawing a local rendition the
  whole time, so `renderLightboxStill` paints that first (the tile's own bitmap, free
  out of the browser's cache, or the largest local thumbnail — the thumbnail route
  always passes `allowNetwork: false`), asks for the original behind it, and falls
  back to the local rendition it had when the original cannot be produced. Two failures
  came from the missing step: a preview that arrived late was preceded by an empty
  stage, and one that never arrived left the stage empty for good — with the arrows
  looking dead because every page was the same blank rectangle.
- **The animation is optional to every caller.** It is skipped when there is no tile to
  fly from (a failed or not-yet-loaded thumbnail), no layout to measure, or under
  `prefers-reduced-motion`. A preview has to work identically without it.
- **Zoom magnifies the photograph, and only the photograph.** The transform is on
  `#lightboxImage`: the panel, the overlay and the stage the reader is pointing at do not
  move with it, because magnifying the interface along with the photo is the failure
  this rules out. `transform-origin: 0 0` with an explicitly computed `translate`/`scale`
  is what lets the anchor arithmetic be stated in one coordinate space — the point under
  the fingers stays under them (`zoomTo`), which is also what makes a corner of a photo
  reachable without panning.
- **A magnified photograph can never be panned off the stage, and an axis with no slack
  is centred instead.** The clamp is on the photograph's own fitted rect, not on the
  element that holds it (`zoomClamp`): a photo narrower than the stage stays centred
  horizontally however far it is zoomed, and one that overflows an axis pans only as far
  as its edge. That is why an off-centre pinch does not always hold its anchor — at the
  bound there is nothing to hold it with — and why a check for the anchor has to pick a
  point that is on the photographed pixels with the clamp's slack to spare.
- **A gesture does not animate; a step the reader took does.** A transition on every wheel
  tick trails the fingers by its own duration, so the wheel/pinch path forces
  `transition: none` and re-arms the settle once the gesture goes quiet, while `+`, `-`
  and `0` animate — one change, with no gesture behind it.
- **Zoom belongs to the photograph, not to the view.** Paging resets it instantly (the
  reader did not ask for that change), closing resets it *before* the return travel starts
  (a shrinking photo underneath the copy flying the other way is two motions at once),
  and a repaint of the same photo — hearting it from the preview — keeps whatever the
  reader set. A clip is never zoomed at all: a wheel over a clip is next to its scrub bar
  and its volume, and its transport owns its own gestures.
- **The preview panel carries the actions that have no other doorway.** "Open in Photos"
  is the one action here that leaves this app, and it had no control on this surface;
  "Show in All Photos" (the tile's hover tool, and the menu), "Show Similar Photos" (the
  menu) and selecting (a click on the tile) each already have theirs, so the chips that
  duplicated them were removed rather than kept in step by hand.
- **A menu item that cannot act is greyed out from an answer, never from a guess.**
  "Show Similar Photos" is the one item whose enabled state is not on the row — whether a
  photo has a group is a fact about a grouping pass that ran in the background — so it is
  built live and corrected from `GET /api/photo/{id}/similar` under the token
  `tileMenu.lookup` guards, and only a *definite* "analysed, no group" greys it out:
  "not analysed yet" keeps a live item, because its page says something different and
  true.
- **The preview travels; a clip's poster frame is what travels.** For a clip the
  hand-over waits for `loadedmetadata`, which is bounded by `preload="metadata"` and
  therefore costs no bytes of the body — and the waiting element still gets the
  `lightbox-entering` opacity hold, because the frame on screen behind the travelling
  copy *is* that clip's poster. Holding it until the clip could play would hold a
  frame that is already visible for however long the export takes.
- **`/api/photo/{id}/video` must stream a range, and it must not buffer the file.**
  Every other route answers from `Data` because a 2048 px JPEG is a `Data`. A clip is
  not: `AVAssetExportPresetPassthrough` keeps the original codec and the original
  container, so a 4 GB 4K clip is 4 GB. Reading it into a `RouteResult` before the
  first byte goes out turns a seek into a wait for the whole file, holds it in memory
  while it writes, and makes the server's memory proportional to what the reader
  happened to open. Hence a file-backed `RouteResult` and a 512 KB read chained off
  each write's completion rather than a blocking read on the connection queue — the
  same reason the thumbnail path is off-actor.
- **The chunked write chain has four ways to be silently wrong**, all of which
  corrupt the *next* response rather than this one: the keep-alive re-arm must happen
  exactly once, after the final chunk's completion (two re-arms desynchronise the
  connection); a mid-body read error must **close** rather than write a short body
  under a `Content-Length` that promised more (the client waits for bytes that will
  never come); `close()` cancels the task mid-body, so the chain must not resurrect
  the connection afterwards; and a client that disconnects must end the chain on the
  completion's `error` rather than spin. `HTTPConnection.send` must therefore stop
  unconditionally overwriting `Content-Length` with `response.body.count` — for this
  case the body is empty and the length is the range.
- **`Range` is parsed, never obeyed by reflex.** `bytes=a-b`, `bytes=a-` and
  `bytes=-suffix` are honoured; `start >= size` and `a > b` are `416` with
  `Content-Range: bytes */size`; an **unparseable** range and a **multi-range** one
  are both ignored and answered `200` with the whole file. Multipart ranges are
  optional in RFC 9110 and the framing risk is not worth taking. Answering a bad
  range with a `500` or with the wrong bytes is the failure; serving the file is a
  correct answer to a request the client can recover from on its own.
- **The clip's `<video>` is paused and emptied on *every* render, not only on close.**
  `renderLightbox` is also the repaint path for a favourite toggle applied from the
  lightbox, and the bug the queue reindexing comments describe — something still
  running underneath the next photo — arrives in this feature as sound rather than a
  stale image. Pausing *before* the source is removed is the load-bearing order:
  dropping `src` from a playing element does not reliably stop it, because the media
  stack may be mid-buffer. Removing the attribute rather than assigning `''` is what
  lets the decoder and the open request go, and `load()` is what tells the element it
  has no resource.
- **A retained `<video>` is a resource leak, so `hideLightbox` tears it down.** Not
  `hidden = true`: a paused-but-attached clip holds its decoder and its half-open
  export request for the rest of the session, and the next open races a resource the
  previous one still owns. The same reason clears the still's `src`.

---

## 9. Deliberate non-goals

- No "delete everything below score X". Ever.
- No way to re-score the whole library. `analysisPixelSize` is exposed read-only over
  HTTP precisely so it cannot trigger a full run.
- No writing to the Photos library other than deletions you ask for. Deletion is one
  step: the Delete button, `⌫` or `Delete`, a tile menu's item and the preview's own
  button all build a *spec* and send it to `/api/delete` through one function. Nothing
  else in the app calls that route. There is no staged list and no undo — the deletion
  goes to Recently Deleted, and the server refuses it outright if the set no longer
  resolves to the fingerprint the count was printed with.
- **Clips are scored, not grouped.** Videos are first-class assets: enumerated,
  scanned, scored, browsable, playable, favouritable and deletable under exactly the
  same protections as a photograph. What they never get is a Similar Group. A video
  is sampled at 10%, 50% and 90% of its duration and takes the **median** of those
  frames' scores. It gets no FeaturePrint, so it never becomes a group member and
  never enters the group builder's input.
  `analyzeFrames` makes both facts one call, because "no vector for a clip" is a
  property of what a clip *is* rather than of which pass happens to be running.
  `import AVFoundation` appears in `VideoLibrary.swift` and nowhere else, so the
  video path cannot leak into the image path by accident.
- No transcoding or re-muxing. `GET /api/photo/{id}/video` is a byte range of what
  Photos holds, exported once through `PHAssetResourceManager` and cached under
  Application Support — the name says `video`, not `stream`, because a name that
  promised a stream would invite a caller to expect one.
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

- Ad-hoc signing means a rebuilt app may re-prompt for Photos permission, and a
  self-update installs a freshly signed bundle, so it does the same. A Developer
  ID signature would keep the grant stable; ad-hoc is what a dependency-free local
  build can do.
- **The cache grows by ~90 MB** once FeaturePrints are computed, and there is **no
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
- **A clip in HEVC does not play in Chrome.** The export is
  `AVAssetExportPresetPassthrough` — no re-encode, so it is fast, lossless and keeps
  whatever codec Photos holds, which on any iPhone-shot library since 2017 is HEVC in
  a `.mov`. Safari and `WKWebView` play that; Chrome does not, and shows a broken
  player. Accepted: the shipped presentation *is* `WKWebView`, so the only affected
  user is somebody who has deliberately opened PhotoCleaner in their own browser and
  who has a HEVC clip. The alternative — transcoding to H.264 on a click — means
  re-encoding up to 4 GB on the request path, for a browser that is not the product.
  **What it would take to measure the cost**: time `AVAssetExportSession` for one
  known 4K clip at `AVAssetExportPresetHighestQuality`, on the same machine, and
  compare it against the passthrough export of the same file.
- **The clip export cache is bounded, and the bound is a guess.** Under Application
  Support, evicted least-recently-used-first until the directory is under **2 GB and
  32 files**, whichever bites first; every eviction is logged. The bound exists because
  an unbounded video cache on a 53k-asset library is a disk-fill bug, but the numbers
  are not measured: they were chosen to hold "a handful of clips you are actually
  reviewing" without becoming the largest thing the app writes. **What it would take
  to measure it**: record the mean and p95 export size and the viewing cadence over a
  real review session, and set the bound from the distribution rather than from taste.
  A cache miss only costs a re-export from Photos, so a bound that is too small is a
  performance annoyance rather than a correctness problem — which is why it can be
  tuned later without a migration.
- **The export cache is keyed on the identifier alone, and is not invalidated on
  modification.** A clip edited in Photos keeps serving the bytes exported before the
  edit until its entry is evicted, and `evict(identifier:)` is called from deletion
  only, so the file outlives a modification. What it would take to fix: include the
  modification date in the cache filename, which the `assets` row already carries, so
  an edited clip simply misses and re-exports. This was left alone because it is a
  narrow case with a bounded cost — an extra export — against a change to the cache's
  key format.
- **Clip playback is verified at the HTTP layer and in jsdom, but not by eye.** Against
  the real library (54,614 assets, 1,953 clips) a scored clip serves
  `200 video/quicktime` at 1.23 GB, `Range: bytes=0-99` → `206` with
  `Content-Range: bytes 0-99/1234186379`, `bytes=5000-5099` → genuinely different bytes
  (offset 0 is a valid MP4 `ftyp` box), and `bytes=99999999999-` → `416`.
  `tools/web-ui-tests.mjs` runs 49 checks against that server, all green, including
  the fourteen video ones: the media control, a clip rendering as a `<video>` with the
  poster and no autoplay, and teardown on close and on paging. What is **not** proven
  is what only pixels can answer: the lightbox hand-over timing (does
  `loadedmetadata` arrive fast enough for the poster frame to read as the video, or is
  there a visible gap), and whether `.tile-duration` collides with `.tile-check` or
  `.tile-anchor-label` on a real grid — the duration is offset to `bottom: 30px` under
  `.tile.anchor` precisely because those two marks exist.
- **A clip is scored from up to three frames, and that is a judgement, not a
  measurement.** `representativeTimes` samples 10%/50%/90% of the duration and the
  median wins, so one black leader frame or blown highlight cannot set a clip's
  score. Nobody has compared that against a human ranking of the same clips, and
  nobody has checked whether three frames is the right number — a clip whose only
  interesting content is between the samples scores on frames of something else.
  **What it would take to measure**: score a set of clips at 1, 3 and 9 frames and
  have a person rank them, then ask how often the ordering changes.
- **A `PHAssetMediaType.unknown` fetch returns nothing, silently.** `.unknown` is the
  *unknown* type, not "every type" — Photos holds no assets of it, so
  `fetchAssets(with: .unknown, …)` answers 0 rows with no error, no exception and no
  warning. It is the worst failure available to a library scan: an instant walk, an
  empty cache, and a status of `up_to_date` — a green run and a blank grid. It is
  what the first implementation of `fetchScannableAssets` did, and the whole library
  was invisible for that reason. The media type is therefore narrowed by the *type
  argument*, one fetch per type, merged into one ordered walk; see the comment on
  `fetchScannableAssets` for the measured table. **What would reintroduce it**:
  passing `.unknown`, or widening the predicate and calling the result "one query".
- **`PHFetchOptions.predicate` is not SQL, and an unsupported one aborts the process.**
  An unevaluable predicate raises `NSInvalidArgumentException` from inside Photos —
  an Objective-C exception, so it cannot be caught in Swift and cannot be reported as
  an error; the app simply dies. Verified on this SDK: `TRUEPREDICATE` raises
  `Unsupported predicate in fetch options`. Only the `mediaType ==` forms used by
  `scannableMediaPredicate` are known to be safe.
- **The whole video path was green in CI and broken in the product.** The export step
  deleted its own output: `defer { removeItem(at: temporary) }` in `VideoLibrary.export`
  ran *after* the return value was computed and *before* the caller received the URL,
  so every clip exported correctly and was then unlinked before `install` could move
  it — a `500` with `NSCocoaErrorDomain Code=4` on every single clip. No test caught
  it because every video test either covered the Range parser or seeded a finished
  file on disk, and **no test of this code path ever exported anything**: the bug
  exists only while the file is being written. The general lesson, now the reason the
  suite includes `VideoRouteTests`: cover the seam where a file is *produced*, not
  only the code that consumes one that already exists.
- **The analysis deadlines are bounds, not repairs, and the numbers are judgements.**
  When PhotoKit never answers a request (§5.4) the asset is now recorded as `failed`
  with no automatic retry — the retry would return it to the front of the queue and
  re-block the pass for another whole deadline — which means the *pass* finishes and
  the *asset* waits for an explicit **Retry**. Nothing here makes PhotoKit answer; it
  makes the run survive the silence. 120 s for an image and a frame, 300 s for a
  clip's `AVAsset` (which may be a whole cloud download) were chosen to sit far beyond
  every healthy request measured on a 54,614-asset library and far short of "never",
  not from a distribution of real latencies. `VideoStreamer.videoAsset` — the same
  `requestAVAsset` call, duplicated for fMP4 playback — is left unbounded on purpose,
  because a stall there costs a player, not the pass.
- A scan is not a consistent snapshot: the library can mutate mid-enumeration. That is
  handled, but not prevented.
- **Self-update cannot install everything.** `UpdateTarget.plan` refuses a bundle that
  is not an `.app`, one running from a mounted disk image (the write would vanish on
  eject, whatever the volume's own flag says), and one in a folder this process cannot
  write — which includes `/Applications` on a Mac where it needs authentication. Each
  refusal is reported in the title bar's arc rather than discovered after a 15 MB
  download.
- **Self-update replaces the running bundle.** There is no way to launch the new copy
  from inside the process that is about to be replaced, so the install schedules a
  relaunch against the old pid and exits. The outgoing bundle is moved aside first and
  put back if the swap cannot be verified, so a failed update leaves the previous
  version installed rather than no app at all.
- The updater downloads over HTTPS from one exact feed — this repository's
  `releases/latest` — and refuses any asset URL whose scheme is not `https`.
  `smoke-test.sh` holds the binary to that one URL, so a second outbound host cannot
  be introduced quietly.

---

## 11. How this is verified

There is no Xcode project and no test framework dependency — the suite is a plain
executable, because SwiftPM does not work here.

1. **`./run-tests.sh`** — the regression suite, over the production sources compiled
   unmodified. `./run-tests.sh --list` prints how many cases are registered; the run
   itself reports pass, fail and known-bug counts. It covers selection resolution,
   the count contract, favourite protection, keyset pagination over tied values, the
   analysis state machine, HTTP parsing and single-response latching, timeline
   ordering, confirm tokens, albums, similar groups, schema migration, the Photos
   authorization gate, self-update, the icon, the window's launch-flag parsing,
   shutdown relay and navigation policy, and — since schema version 5 — the video
   route end to end over a real socket: `Range` handling, `206`/`416`, `HEAD`
   framing, keep-alive across a streamed body, the media filter and the
   identifier-before-PhotoKit refusal gate. It needs no Photos library and no network.
   **Serialise it against `build.sh`.** The script regenerates
   `Web/GeneratedWebAssets.swift` in place and then compiles it, so a concurrent
   build fails with "input file was modified during the build" — which reads like a
   source problem and is not one.
2. **`./build.sh`** — compiles with `-warnings-as-errors` and assembles the bundle.
3. **`./smoke-test.sh`** — audits the real cache and, importantly, **what the app has
   written outside Application Support and Logs**. The windowed app is allowed exactly
   one preferences key; anything else fails the run. It also greps `web/` for the
   phrases a removed control would leave behind, so a control *returning* fails the run
   even in a build where nobody opens the panel — see the note on paired absence and
   presence checks below.
4. **`node tools/web-ui-tests.mjs <url>`** — the `web/` half, driven in jsdom against a
   running server. Not wired into CI; see [WEB-UI-TESTS.md](WEB-UI-TESTS.md) for how
   to run it and the five things jsdom does not have. **A change to `web/` needs this
   suite too** — `run-tests.sh` compiles `web/` into the binary but asserts nothing
   about how it behaves. Three things to know before trusting a run: it needs jsdom
   (`JSDOM_PATH`) **and a server whose cache has rows in it**, because the harness
   waits for a first tile and an empty library renders none — so it fails at boot on a
   clean machine rather than skipping, which looks like a client bug and is not one.
   It must be pointed at the build under test (see the handoff below). And a check
   that depends on a *request* happening must poll for it rather than sleep: two of
   the video cases flaked at a fixed `settle(700)` on a machine whose videos-filtered
   page took longer to arrive, and passed once they waited for the condition instead.
5. **Against the real library**, for anything structural that needs real PhotoKit or
   Vision behaviour.

**The single-instance handoff will silently test the wrong binary.** A second launch
on a taken port finds the instance that owns it, hands the address over and exits 0
(`PhotoCleanerApp.handleStartFailure`) — under `--no-browser` it hands over and
prints one line to stderr. So a stale server keeps serving, a route added since it
started answers 404, and nothing reports an error: the request looks like a wrong
answer rather than a wrong *server*. This is not hypothetical; it produced a confident
but false "the live server does not echo `media`" reading before the process start
time was checked. **Before trusting any live-server result, confirm the process is
the build under test** — `ps -o lstart -p $(lsof -ti tcp:<port> -sTCP:LISTEN)`, or
ask for a field only the new build emits (`library.videos`) rather than only for
fields it has always had.

Set `PHOTOCLEANER_SLOW_TESTS=1` to include the cases that wait on production
timeouts.

**Current state**, for whoever picks this up next. `./run-tests.sh --strict` reports
**321 passed, 0 failed, 2 skipped** (the two are the production-timeout cases above);
`./build.sh` is clean under `-warnings-as-errors`; `./smoke-test.sh` reports 56 passed;
and `node tools/web-ui-tests.mjs` reports **49 passed, 0 failed** against a server on a
populated library, fourteen of those being the video cases. Two things are
consequently unproven and are recorded in §10 — the lightbox hand-over timing for a
real clip, and whether `.tile-duration` collides with `.tile-check` or
`.tile-anchor-label` on a real grid. Neither is a question the test suites can
answer; both need a window.

**A new test is only worth having once it has been seen to fail.** When changing
`CacheStore` pagination, `resolveSelection`, or the deletion path, prove the case is
load-bearing by reverting the guarantee in a scratch tree and watching it fail. Tests
that have never failed prove nothing.

**An absence check is satisfied by deleting the information.** This is the failure
mode of every check phrased as "X must not appear" — including the grep in
`smoke-test.sh` that keeps the favourite-protection control out of `web/`. Removing a
control and *relocating* what it said looks identical to removing it and losing the
sentence, and the absence check passes either way. So each one is paired with the
presence half of the same claim: the greps that assert `protectFavorites` and
`protectedCount` are gone are paired with one asserting `"protected from deletion"` is
still in `web/app.js`, and the jsdom case that finds no switch is paired with one
asserting a favourite's heart and accessible name still say they are protected. Keep
them together — deleting the presence half turns the pair back into a check that
rewards silence.

---

## 12. Commands

```sh
./build.sh                       # compile + bundle + draw icon + ad-hoc sign
./run-tests.sh                   # full suite
./run-tests.sh --list            # how many cases are registered
./run-tests.sh --only "group album filter"   # one suite, matched as a substring
./run-tests.sh --strict          # also fail on known-bug cases
PHOTOCLEANER_SLOW_TESTS=1 ./run-tests.sh      # include the cases that wait on real timers
./smoke-test.sh                  # real-cache and filesystem audit
./smoke-test.sh --no-server      # what CI runs: no instance to inspect

./make-dmg.sh --version 1.2.3    # build, package and verify the DMG
./make-dmg.sh --version 1.2.3 --no-build       # package what is already in dist/
./make-dmg.sh --arch x86_64 --version 1.2.3    # an Intel DMG

node tools/web-ui-tests.mjs http://127.0.0.1:8791   # the web/ client, in jsdom

./photo-cleaner                  # build if needed, start, show the window
./photo-cleaner --foreground     # logs to this terminal
./photo-cleaner --browser        # the default browser instead of the window
./photo-cleaner --no-browser     # no interface at all; just the server
./photo-cleaner --port 8766      # a different loopback port
./photo-cleaner --version        # the version stamped into this build

lsof -nP -iTCP:8765 -sTCP:LISTEN # confirm the loopback-only binding
sqlite3 -readonly ~/Library/Application\ Support/PhotoCleaner/cache.sqlite "PRAGMA user_version;"
rm -rf ~/Library/Application\ Support/PhotoCleaner ~/Library/Logs/PhotoCleaner
```

`--only` matches a suite name as a case-insensitive substring, so it selects by what
a suite is called rather than by what it contains: `--only group` runs every group
suite, `--only timeline` the All Photos one.

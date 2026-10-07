# PhotoCleaner regression tests

There is no SwiftPM on this machine, so these are not an XCTest target. They are
compiled *into the same binary as the production sources* by `../run-tests.sh`:

```sh
../run-tests.sh                 # compile + run everything
../run-tests.sh --only timeline # one suite, matched as a substring of its name
../run-tests.sh --list          # how many cases are registered
../run-tests.sh --strict        # also exit non-zero when a known bug still fails
../run-tests.sh --help          # the runner's own usage
PHOTOCLEANER_SLOW_TESTS=1 ../run-tests.sh   # add the cases that wait on real timers
```

`run-tests.sh` folds `web/` into `Sources/PhotoCleaner/Web/GeneratedWebAssets.swift`
first — that file is generated and gitignored, and
`Sources/PhotoCleaner/Web/WebAssets.swift` will not compile without it, so the
suite has to produce it rather than assume `./build.sh` ran. It generates into its
own temporary directory and moves the result into the tree only when the bytes
differ, because `build.sh` writes the same file and `swiftc` refuses a source file
that changes underneath it mid-build. It then compiles every file under `Sources`
**except
`main.swift`** (tests own the entry point) together with every file here, into a
throwaway executable in a temporary directory, and removes that afterwards.
Apart from the regenerated web-assets source, nothing it does touches `dist/`, the
real cache at `~/Library/Application Support/PhotoCleaner`, `settings.json`, the
application log, or `Photos Library.photoslibrary`. Every fixture is a temporary
SQLite file; the only routes exercised are the ones that cannot delete anything,
and no route that reaches `PhotoLibrary.delete` is ever given a selection that
resolves to anything.

`PHOTOCLEANER_ARCH` works here as it does in `build.sh`, so a release built for one
architecture tests that architecture rather than the runner's.

Because the production code is compiled in, **a failing case means the real code
misbehaved** — there is no mock to drift out of sync. Where a production member is
`private` (`Router.resolveSelection`, `HTTPConnection`) the tests reach it the way
a browser does: through `Router.handle`, or over a real loopback socket. Nothing
here re-implements the logic it is testing.

## `knownBug:` markers

A case may carry a `knownBug:` string. Such a case asserts the behaviour the
production code *should* have and currently fails; the string documents the defect
it pins. They are reported in their own section and, by default, do **not** fail
the run — so a newly broken invariant is never lost in the noise of a defect that
is already known. `--strict` makes them fail the run too. When one starts passing,
the runner says so and the marker should be deleted.

## Layout

| File | Covers |
|---|---|
| `TestHarness.swift` | the assertion harness, the case registry, environment gates |
| `TestSupport.swift` | fixtures: temporary `CacheStore`, `Settings`, `Router`, request/response helpers |
| `SelectionTests.swift` | `Router.resolveSelection` and the count contract, via `/api/selection/preview` |
| `FavouriteProtectionTests.swift` | favourite protection, including failing closed |
| `PaginationTests.swift` | keyset pagination, `ORDER BY` ↔ keyset consistency, cursors |
| `TimelineTests.swift` | `TimelineDirection`, the All Photos routes, the unfilterable window |
| `StateMachineTests.swift` | `pending → analyzing → done/failed/unavailable`, claims, requeues, rescans |
| `ConfirmTokenTests.swift` | the deletion fingerprint and the 409 path |
| `RecordTests.swift` | `PhotoRow`/`PhotoCursor`/enums, query parsing, the wire contract |
| `EventBusTests.swift` | SSE fan-out, heartbeat vs. retained snapshot, `Settings` |
| `AuthorizationTests.swift` | the Photos gate: which routes refuse, and the routes that must not |
| `SchemaTests.swift` | the cache schema and its migrations |
| `PresentationTests.swift` | launch flags, the shutdown relay, the window's navigation policy |
| `UpdateTests.swift` | self-update: version comparison, the release feed, the install target, the phases |
| `IconTests.swift` | the drawn icon: it renders, its body separates from every shipped desktop by luminance, it stays neutral, and its tile grid is countable at 32px |
| `ThumbnailTests.swift` | the thumbnail size ladder: nearest rung, and ties downwards |
| `SimilarGroupTests.swift` | FeaturePrint storage, the group builder, face aggregation, the Best Shot ranker, the group cache and routes |
| `HTTPServerTests.swift` | the connection end to end: caps, keep-alive, pipelining, one response per connection |
| `VideoTests.swift` | the pure logic behind video support: frame sampling, the media dimension and its placeholder budget, `Range` resolution, the median, schema version 5, clips-never-group, and the wire shape |
| `VideoRouteTests.swift` | `/api/photo/{id}/video` over a real loopback socket: refusals, `Range`, `HEAD`, keep-alive, and the media filter through `Router` |

## The icon cases measure a rendered image

`IconTests` is the one suite whose subject is not a Swift value. `tools/make-icon.swift`
has top-level code and cannot be imported into the test binary, so the cases
invoke it, expand the `.icns` with `iconutil`, and measure the PNG it wrote. That
is the stronger form of the assertion — it measures the artifact rather than a
reimplementation of the drawing — and it means the cases fail if the *drawing* is
wrong, not merely if a constant moved.

Three things about measuring an icon this way cost real time to find, and each of
them first produced a test that passed when it should have failed:

- **Every pixel against every wallpaper.** A neutral icon has no hue to separate
  itself from the desktop with, so the body gradient has to clear the desktop's
  luminance. The whole icon sits on the wallpaper, so the figure is a min over
  both ends of the ramp and all of them. Checking light-end-on-light and
  dark-end-on-dark instead reports a graphite body as a comfortable pass — its
  dark end scores 12.94:1 on a light desktop — while its light end is invisible
  at 1.09:1 on a dark one.
- **The body, not the mark.** The mark is white. A whole-image maximum measures a
  tile, and since white is trivially visible on any desktop, the dark-desktop
  check then passes whatever the ramp is.
- **Strips along the straight edges, over the middle half of the width.** The
  squircle's corner radius is 22.4% of the side, so the top and bottom edges are
  cut away outside 25%…75% of the width, and those pixels are stored as
  premultiplied transparent black. Read as colour they report a body far darker
  than any in the ramp — the measurement came out at 1.14:1 for a ramp whose dark
  end really scores 1.85:1.

The floors are set by sweeping the parameter each one guards until it broke, so
they are wide on purpose. Two claims about the mark that measurement did *not*
support — that the tile gap and the opacity run were both needed for Dock
legibility — are recorded as measured facts in `tools/make-icon.swift` and
`docs/ARCHITECTURE.md` instead of being left standing as justifications.

## Similar-group cases use real Vision output

`SimilarGroupTests` asks Vision for real `FeaturePrintObservation`s rather than
faking them, because there is no public initialiser for a synthetic one and a
fixture built from invented numbers would only test itself.

That forces the fixture to be *calibrated*, and the calibration is the interesting
part. A FeaturePrint turns out to be almost blind to colour and highly sensitive
to texture: measured, solid red and solid green sit **0.31** apart — inside the
0.35 grouping threshold — while two *different* random noise fields are **0.0056**
apart. Neither can express "clearly different photos". What separates images is
arrangement, and only with full-bleed contrast (with a grey under-fill,
perpendicular bands measured 0.24 apart instead of 0.99).

So `TestPattern` is built from full-bleed structural patterns whose distances have
been measured, and the first case in the suite re-checks that measurement on every
run. Without it, a case asserting "these stay apart" would also pass if the builder
compared nothing at all — zero groups is what an empty comparison produces too.

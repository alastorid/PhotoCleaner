# PhotoCleaner regression tests

There is no SwiftPM on this machine, so these are not an XCTest target. They are
compiled *into the same binary as the production sources* by `../run-tests.sh`:

```sh
../run-tests.sh                 # compile + run everything
../run-tests.sh --only timeline # one suite
../run-tests.sh --list          # how many cases are registered
../run-tests.sh --strict        # also exit non-zero when a known bug still fails
PHOTOCLEANER_SLOW_TESTS=1 ../run-tests.sh   # add the cases that wait on real timers
```

`run-tests.sh` compiles every file under `Sources` **except `main.swift`**
(tests own the entry point) together with every file here, into a throwaway
executable in a temporary directory, and removes it afterwards. Nothing it does
touches `dist/`, the real cache at `~/Library/Application Support/PhotoCleaner`,
`settings.json`, the application log, or `Photos Library.photoslibrary`. Every
fixture is a temporary SQLite file; the only routes exercised are the ones that
cannot delete anything, and no route that reaches `PhotoLibrary.delete` is ever
given a selection that resolves to anything.

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
| `ThumbnailTests.swift` | the thumbnail size ladder: nearest rung, and ties downwards |
| `SimilarGroupTests.swift` | FeaturePrint storage, the group builder, face aggregation, the Best Shot ranker, the group cache and routes |
| `HTTPServerTests.swift` | the connection end to end: caps, keep-alive, pipelining, one response per connection |

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

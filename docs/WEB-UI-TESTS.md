# The web client in jsdom

`./run-tests.sh` covers the Swift half of PhotoCleaner. Everything in `web/` — the
grid, the Space-to-preview toggle, the context menu, the delete flow's wiring — is a
second half, and this is how it gets exercised.

Three files, none of them shipped:

| File | What it is |
| --- | --- |
| `tools/web-ui-harness.mjs` | Loads the real client in jsdom against a running server |
| `tools/web-ui-tests.mjs` | The checks themselves |
| `package.json` | Declares `jsdom` as a dev dependency, for this harness only |
| `package-lock.json` | Pins that version — a resolution record, not a copy of anything |

The point of the arrangement is that **nothing about the client is reimplemented**.
`web/index.html` and `web/app.js` are read off disk and `eval`'d as-is, so the DOM the
tests poke at is the DOM the app builds for itself. The harness supplies a browser and
a way to read the result, and stays out of the way otherwise. A harness that mocked
the client would only prove the mock works.

## Running it

The harness talks to a live PhotoCleaner over HTTP, so start the server first:

```sh
npm install                                   # once — resolves jsdom
./photo-cleaner --no-browser --port 8791 --foreground &
npm run test:web -- http://127.0.0.1:8791     # or: node tools/web-ui-tests.mjs <url>
```

jsdom is fetched by npm at install time and is **never vendored** — no copy of it, and
of its dependencies, is committed. `node_modules/` is gitignored, so what the repository
carries is the manifest and the lockfile: the declaration and the exact version, nothing
else. That is the whole extent of the app's exposure to a package manager, and it is a
developer dependency of a test harness that ships in nothing.

Two things follow from that, worth stating because both have bitten:

- **`node_modules/` is not portable.** It is a working directory, not an artifact. Clone
  or `git clean` and `npm install` again. Nothing else in the repo depends on it existing.
- **A second server instance cannot share the cache.** The tests need their own port, but
  two instances against one `cache.sqlite` means the second reconciles nothing and serves
  an empty grid — the harness fails with "the client never rendered a tile" rather than
  anything about jsdom. Run one instance, or point the new one at a scratch cache.

It is **not** wired into `run-tests.sh` or CI. That is a known gap, not an oversight to
rediscover: CI runs build, `run-tests.sh` and `smoke-test.sh` only.

## Writing a check

```js
await check('what it guarantees', async (app) => {
  app.click('groupsButton');
  await app.settle(250);
  assert(app.$('someId').hidden === false, 'the thing did not happen');
});
```

Every `check` gets a **fresh app** — new window, new DOM, new boot — so no state leaks
between cases. The harness waits for the first tile to render before returning, so
there is no need to sleep for boot; it does fail loudly if the client throws while
booting, which is usually the real bug.

Useful bits of the harness surface: `app.$`, `app.key`, `app.click`, `app.keyUp`,
`app.settle(ms)`, `app.tileIds()`, `app.tileIdsIn(selector)`, `app.window`, `app.close()`.

`settle` is a real timer, so prefer polling over a fixed guess whenever a page fetch is
involved — see `openGroups` for the shape of that.

## The five things jsdom does not have

Each of these is a trap that has already cost time, so the workarounds are worth
knowing before you hit them.

**No layout.** Every `getBoundingClientRect()` returns zeroes. Code that measures the
screen therefore takes its "nothing to measure" path, which is *correct* but will make
a test pass for the wrong reason. The animation tests supply boxes explicitly:

```js
const layout = withLayout(app);
layout.place(tile, { x: 100, y: 200, width: 200, height: 200 });
layout.loaded(tile.querySelector('img'));   // jsdom never fetches images
// …and in a finally:
layout.restore();
```

There is no painting order and no hit-testing either, which is the sharper edge of the
same absence: `dispatchEvent` delivers a click to the element named, whatever is drawn
over it. So a check can pass with the control underneath the thing it controls — as the
lightbox's ‹ › buttons were, once the still gained a `transform` (which puts an element
in the positioned painting layer, where DOM order decided and the photograph won). Only
`document.elementFromPoint` in a real browser, or an actual pointer, catches that class
of bug; see ARCHITECTURE §8 on the arrows.

Stub `getBoundingClientRect` **per element**, never on `Element.prototype`. jsdom
resolves it per concrete element class, and those wrappers delegate back up — patch the
prototype and the stub calls itself until the stack runs out. For the same reason
`withLayout` *deletes* its overrides on restore instead of assigning the original back:
jsdom shares element classes between windows, so an own property left behind is found
already patched by the next test.

**No image loading.** `complete` is false and `naturalWidth` is 0, so the client
rightly refuses to animate a thumbnail that has no pixels. `layout.loaded(image)`
overrides those three properties on one element. `HTMLImageElement.prototype.decode`
does not exist at all, which is why the client has a `load`/`error` fallback path — and
why `renditionArrives(app)` dispatches a `load` event when a test needs a photo's
bitmap to have arrived.

**No CSS transitions.** Nothing moves, and `transitionend`/`animationend` never fire.
Assert on the states the code sets itself — classes, the `hidden` attribute, inline
styles — never on pixels in flight. For a pose that exists only for an instant before a
transition starts, record it at insertion: the inline styles are cleared to release the
transition, so reading them a tick later finds the release, not the pose. That is what
the flight-recording inside `withLayout` does.

**No `IntersectionObserver`.** Stubbed to a no-op by the harness. A lazy thumbnail
therefore never loads on its own, and `scrollIntoView` is stubbed too.

**No media stack.** `HTMLMediaElement.play`, `.pause` and `.load` are *not
implemented*, and — this is the trap — jsdom reports each one on the **virtual
console per call** rather than throwing. So the failure is invisible to a `try`/`catch`,
and it lands in the harness's `errors` array as noise a reader will misread as a client
bug. Wrap the call to assert it happened; never read `video.paused` to assert it did
not, because that property is always `true` in jsdom regardless of what the code did.
For the same reason, assert *teardown* — that the element is gone and its `src`
attribute removed — rather than that playback stopped, and keep any clip-touching case
guarded on the element actually having a `src` so a library with no videos never
triggers a report at all.

## Things the harness deliberately does not stub

`fetch` is redirected at the live server rather than faked, so the client's own paging
and index arithmetic run on the real path. Two routes are intercepted — `/api/delete`
by `interceptDeletes` and `/api/photos/reveal` by `interceptReveals` — and only
because they act *outside* this process: one destroys photos in somebody's real
library and the other puts the Photos window in front of whoever is at the machine. A
suite that emptied a library, or stole focus on a desktop, to check a wire format is
not worth what it would cost.

## Prove it can fail

Same rule as the Swift suite, and it matters more here because a jsdom harness is easy
to write so generously that it passes on anything. Two failure modes to watch for:

- **Passing for the wrong reason.** The most common one here: no layout, so the code
  under test took its "cannot animate" path and the assertion about the animation
  trivially held. If a test asserts something only happens during a transition, supply
  the layout first.
- **Asserting on a literal.** A hardcoded `translate(-800px, -200px) scale(0.2)` passes
  for one photograph from one library and goes red when the server returns a different
  aspect ratio. Assert the geometry ("the centre lands on the tile's centre"), not the
  string.

Then revert the guarantee in a scratch tree and watch the case go red. A test that has
never failed proves nothing.

## Coverage is not the goal

This suite exists to catch wiring regressions in the client — the ones where the button
and the handler and the state field drift apart, or a keyboard path silently stops
reaching the thing the pointer path does. It is not a spec for `web/`, and
`ARCHITECTURE.md` §8 is where the client's real invariants live.

Prefer a few checks that each pin one invariant, written so the failure message names
the guarantee, over a broad sweep that touches everything shallowly. A suite that
asserts every rendered string and every computed style drifts into needing an update
for every cosmetic change, and then gets ignored. When in doubt, ask whether the case
would catch a real regression a user could hit — if not, leave it out.

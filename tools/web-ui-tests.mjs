/**
 * Behavioural checks for the delete flow and the pointer/keyboard model.
 *
 * These drive the *real* client — the same `web/app.js` and `web/index.html` the
 * app serves — in jsdom against a running PhotoCleaner, and assert on the DOM the
 * app builds for itself. Nothing is stubbed except the browser's absence of
 * layout, so a regression in the wiring shows up here rather than in a screenshot.
 *
 *   ./photo-cleaner --no-browser --port 8791 --foreground &
 *   node tools/web-ui-tests.mjs http://127.0.0.1:8791
 */
import { openApp } from './web-ui-harness.mjs';

const base = process.argv[2] || 'http://127.0.0.1:8791';

let passed = 0;
const failures = [];

async function check(name, body) {
  const app = await openApp({ base, pageLimit: 40 });
  try {
    await body(app);
    passed += 1;
    console.log(`  ok    ${name}`);
  } catch (error) {
    failures.push({ name, error });
    console.log(`  FAIL  ${name}`);
    console.log(`          ${error.message.split('\n').join('\n          ')}`);
  } finally {
    app.close();
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertEqual(actual, expected, message) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${message}\n            expected ${b}\n            actual   ${a}`);
}

/** Clicks the tile whose data-id is `id`. */
function clickTile(app, id) {
  const tile = app.window.document.querySelector(`#grid .tile[data-id="${id}"]`);
  assert(tile, `no tile for ${id}`);
  tile.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
}

console.log('delete flow: one step');

/**
 * Withholds the destruction and records what was asked for.
 *
 * Every other request goes to the live server untouched, so the client runs its
 * real path — the real button state, the real fingerprint, the real report and
 * the real reload afterwards. Only the `/api/delete` call is answered here:
 * these tests point at a library somebody actually owns, and a suite that empties
 * it to check a wire format is not worth the photos it destroys.
 *
 * The canned report says everything was deleted, so the client takes its success
 * branch and the assertions can cover what it does next.
 *
 * @return the array each intercepted body is appended to.
 */
function interceptDeletes(app) {
  const sent = [];
  const real = app.window.fetch;
  app.window.fetch = async (input, init) => {
    const path = new URL(typeof input === 'string' ? input : input.url, app.window.location.href).pathname;
    if (!path.endsWith('/api/delete')) return real(input, init);
    sent.push(JSON.parse(init.body || '{}'));
    const ids = sent[sent.length - 1].mode === 'ids' ? sent[sent.length - 1].ids.length : 0;
    return {
      ok: true,
      status: 200,
      async json() {
        return {
          requested: ids, resolved: ids, deleted: ids, missing: 0, protectedFavorites: 0,
          skippedNonImages: 0, unknownIdentifiers: 0, truncated: false, errors: [],
        };
      },
      async text() { return ''; },
    };
  };
  return sent;
}

/**
 * Withholds the hand-off to Photos.app and records what was asked for.
 *
 * The same rule as `interceptDeletes`, for the same reason: "Open in Photos"
 * leaves this process and puts the Photos window in front of whoever is at the
 * machine, and a regression suite is not allowed to steal focus on somebody's
 * desktop to check a wire format. Only that one route is answered here — the
 * client's real path, its toast and its own id all run.
 */
function interceptReveals(app) {
  const sent = [];
  const real = app.window.fetch;
  app.window.fetch = async (input, init) => {
    const path = new URL(typeof input === 'string' ? input : input.url, app.window.location.href).pathname;
    if (!path.endsWith('/api/photos/reveal')) return real(input, init);
    const body = JSON.parse(init.body || '{}');
    sent.push(body);
    return {
      ok: true,
      status: 200,
      async json() {
        return { ok: true, mechanism: 'asset_link', requested: 1, opened: 1, id: body.id,
                 message: 'Photos was asked to open that photo.' };
      },
      async text() { return ''; },
    };
  };
  return sent;
}

/** The fingerprint the server itself resolves a set to, asked over the wire. */
async function serverFingerprint(spec) {
  const response = await fetch(`${base}/api/selection/preview`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(spec),
  });
  return (await response.json()).confirmToken;
}

await check('there is no delete list, and no second control beside Delete', async (app) => {
  assertEqual(app.$('deleteList'), null, 'the panel element is still in index.html');
  assertEqual(app.$('deleteListCommit'), null, 'the Commit button is still in index.html');
  assertEqual(app.$('clearTrash'), null, 'a Clear-list button is still in index.html');
  assert(/deleteButton(?!\w)/.test(app.$('selectionBar').innerHTML), 'the Delete button moved out of the bar');
});

await check('Delete is armed with the count the server resolved', async (app) => {
  const [first, second] = app.tileIds();
  clickTile(app, first);
  clickTile(app, second);
  await app.settle(500);
  const button = app.$('deleteButton');
  assertEqual(button.disabled, false, 'the button was disabled with a selection present');
  // "assets", not "photos": the default media filter admits both, so the noun the
  // button prints has to be able to name a clip. Asserting "photos" here would be
  // asserting the inaccuracy.
  assertEqual(button.textContent, 'Delete 2 assets',
    'the button does not carry the count the server resolved');
});

await check('the count is the resolved one, and it is singular for one photo', async (app) => {
  clickTile(app, app.tileIds()[0]);
  await app.settle(500);
  assert(/^Delete 1 asset$/.test(app.$('deleteButton').textContent),
    `wrong singular/plural or count: ${app.$('deleteButton').textContent}`);
});

await check('Delete with nothing selected is inert, not armed over an empty set', async (app) => {
  assertEqual(app.$('deleteButton').disabled, true, 'the button was live with nothing selected');
  assertEqual(app.$('deleteButton').textContent, 'Delete', 'the button printed a count for nothing');
});

await check('clicking Delete sends the selection to /api/delete, with a fingerprint', async (app) => {
  const sent = interceptDeletes(app);
  const [first, second] = app.tileIds();
  clickTile(app, first);
  clickTile(app, second);
  await app.settle(500);

  app.click('deleteButton');
  await app.settle(600);
  assertEqual(sent.length, 1, `Delete destroyed nothing (${sent.length} requests)`);
  assertEqual(sent[0].mode, 'ids', 'the request was not an explicit set of identifiers');
  assertEqual([...sent[0].ids].sort(), [first, second].sort(), 'the request did not carry the selection');
  assert(typeof sent[0].confirmToken === 'string' && sent[0].confirmToken.length > 0,
    'the deletion carried no fingerprint, so the count on the button was not binding');
});

await check('the fingerprint is the one the server resolved for that set', async (app) => {
  // Asked of the server rather than read off the client, so this asserts the
  // answer that was resolved for the preview was passed through — not that the
  // client agrees with itself.
  const sent = interceptDeletes(app);
  const target = app.tileIds()[0];
  clickTile(app, target);
  await app.settle(500);

  app.click('deleteButton');
  await app.settle(600);
  assertEqual(sent.length, 1, 'the deletion did not go out');
  assertEqual(sent[0].confirmToken, await serverFingerprint({ mode: 'ids', ids: [target] }),
    'the deletion carried a fingerprint the preview never produced');
});

await check('nothing is destroyed before the count is known', async (app) => {
  const sent = interceptDeletes(app);
  const target = app.tileIds()[0];
  clickTile(app, target);
  // The preview is debounced, so the button has not been resolved yet. Both the
  // click and the keystroke must do nothing: this client cannot say how many
  // photos it would destroy, so it does not destroy any.
  assertEqual(app.$('deleteButton').disabled, true, 'the button was armed before the count arrived');
  app.click('deleteButton');
  app.key('Backspace');
  await app.settle(600);
  assertEqual(sent.length, 0, 'a press destroyed photos before the count was known');
  await app.settle(500);
  assertEqual(app.$('deleteButton').disabled, false, 'the button never became live once resolved');
});

await check('⌫ deletes the selection, exactly as the button does', async (app) => {
  const sent = interceptDeletes(app);
  const target = app.tileIds()[0];
  clickTile(app, target);
  await app.settle(500);
  app.key('Backspace');
  await app.settle(600);
  assertEqual(sent.length, 1, `⌘⌫ destroyed nothing (${sent.length} requests)`);
  assertEqual(sent[0].ids, [target], 'the deletion did not carry the selection');
});

await check('a stale "all matching" selection cannot be deleted', async (app) => {
  const sent = interceptDeletes(app);
  app.click('selectAllMatching');
  await app.settle(600);
  assertEqual(app.$('deleteButton').disabled, false, 'the button was dead with a resolvable selection');

  // Moving a bound is what makes the snapshot stale: the saved filter is no longer
  // the filter on screen, so "all" would now mean something else entirely.
  const lower = app.$('lowerRange');
  lower.value = String(Math.min(Number(lower.max), Number(lower.value) + 25));
  lower.dispatchEvent(new app.window.Event('input', { bubbles: true }));
  await app.settle(700);
  assertEqual(app.$('deleteButton').disabled, true, 'the button was live over a stale selection');
  app.click('deleteButton');
  app.key('Backspace');
  await app.settle(600);
  assertEqual(sent.length, 0, 'a stale selection was destroyed anyway');
});

console.log('preview: space is a toggle');

await check('Space on a tile opens the preview and Space again closes it', async (app) => {
  const tile = app.window.document.querySelector('#grid .tile');

  tile.dispatchEvent(new app.window.KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
  await app.settle(200);
  assertEqual(app.$('lightbox').hidden, false, 'Space did not open the preview');
  assertEqual(app.$('lightboxScore').textContent !== '—', true, 'the preview did not load a photo');

  app.key(' ');
  await app.settle(200);
  assertEqual(app.$('lightbox').hidden, true, 'Space did not close the preview');
});

await check('Space no longer toggles the selection', async (app) => {
  const tile = app.window.document.querySelector('#grid .tile');
  tile.dispatchEvent(new app.window.KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
  await app.settle(150);
  const summary = app.$('selectionSummary').textContent;
  assert(/Nothing selected/.test(summary), `Space selected the photo instead of previewing it: ${summary}`);
});

await check('click selects, double-click previews', async (app) => {
  const tile = app.window.document.querySelector('#grid .tile');
  tile.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await app.settle(120);
  assert(!/Nothing selected/.test(app.$('selectionSummary').textContent),
    'a single click did not select');
  assertEqual(app.$('lightbox').hidden, true, 'a single click opened the preview');

  tile.dispatchEvent(new app.window.MouseEvent('dblclick', { bubbles: true, cancelable: true }));
  await app.settle(200);
  assertEqual(app.$('lightbox').hidden, false, 'a double click did not open the preview');
});

console.log('preview: deleting from inside it');

await check('⌫ in the preview destroys the photo on screen', async (app) => {
  const sent = interceptDeletes(app);
  const ids = app.tileIds();
  const tile = app.window.document.querySelector(`#grid .tile[data-id="${ids[0]}"]`);
  tile.dispatchEvent(new app.window.KeyboardEvent('dblclick', { bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, false, 'the preview did not open');

  app.key('Backspace');
  await app.settle(600);
  assertEqual(sent.length, 1, `⌘⌫ in the preview destroyed nothing (${sent.length} requests)`);
  assertEqual(sent[0].ids, [ids[0]], 'the deletion did not carry the photo on screen');
  assertEqual(app.$('lightbox').hidden, true, 'the preview stayed open over a destroyed photo');
});

console.log('preview: it arrives and leaves rather than appearing');

/**
 * Gives the client a layout, which jsdom has none of.
 *
 * The preview's animation measures the tile it is flying out of and the stage it is
 * flying into, so without this there is nothing for it to measure and the travel is
 * correctly skipped — which would make every assertion below pass for the wrong
 * reason.
 *
 * Each element is given its own stub rather than the prototype's, because jsdom
 * resolves `getBoundingClientRect` per concrete element class: patching
 * `Element.prototype` leaves every subclass's own method in front of it, and those
 * delegate back up, so the stub calls itself.
 *
 * jsdom does not fetch images, so a tile's `<img>` is also told it is loaded and
 * given a size: the client declines to fly a thumbnail with no pixels in it, which is
 * right and would otherwise skip the travel here too. Only the tile's own image is
 * given those properties — the preview image is deliberately left "not loaded", which
 * is the state a photograph still being fetched is in, and which the client has to
 * survive.
 *
 * jsdom has no CSS transitions, so nothing here can watch a photograph move. Two
 * things stand in for that. `pose` records the inline styles at the instant a
 * travelling copy is inserted, which is the only moment its start pose exists — the
 * release that begins the transition clears them immediately afterwards. And the
 * states the code owns outright — classes, the `hidden` attribute — are read off the
 * live DOM as usual.
 */
function withLayout(app) {
  const stubs = [];
  const flights = [];

  /**
   * A travelling copy's styles, as a list of steps.
   *
   * A pose only exists in the inline styles, and it does not stay there: the way out
   * sets the start pose and then *clears* the styles to begin the transition, and the
   * way back appends the copy at rest and writes the destination afterwards. So a
   * single read either way would catch the wrong moment — and catching the release
   * instead of the pose would look like "nothing was transformed at all".
   *
   * Every step is therefore kept, and the pose is found by looking for the step that
   * carries a scale, which is the step that says where the photograph is going.
   */
  function watchFlight(node) {
    const flight = { node, steps: [] };
    flights.push(flight);
    const step = () => ({
      left: Number.parseFloat(node.style.left),
      top: Number.parseFloat(node.style.top),
      width: Number.parseFloat(node.style.width),
      height: Number.parseFloat(node.style.height),
      transform: node.style.transform,
      filter: node.style.filter,
      opacity: node.style.opacity,
    });
    flight.step = step;
    flight.steps.push(step());
    // Written as an own property on this one declaration: the client's own writes go
    // through it, and the element's `style` is a fresh object per element.
    const declaration = node.style;
    for (const property of ['transform', 'opacity', 'filter']) {
      const setter = Object.getOwnPropertyDescriptor(
        app.window.CSSStyleDeclaration.prototype, property,
      ) || Object.getOwnPropertyDescriptor(Object.getPrototypeOf(declaration), property);
      Object.defineProperty(declaration, property, {
        configurable: true,
        get() { return setter.get.call(this); },
        set(value) {
          setter.set.call(this, value);
          flight.steps.push(step());
        },
      });
    }
    return flight;
  }

  // Two jsdom details make this need care. `appendChild` is reached through a wrapper
  // per element class that delegates up to `Node.prototype`, so the wrapper is called
  // instead of being replaced by calling through to it — the original is reached via
  // the prototype, or the stub calls itself. And an own property is deleted on the way
  // out rather than assigned back: jsdom shares element classes between windows, so a
  // restored function assigned as an own property would outlive this window and be
  // found already patched by the next one.
  const body = app.window.document.body;
  const append = app.window.Node.prototype.appendChild;
  let inside = false;
  Object.defineProperty(body, 'appendChild', {
    configurable: true,
    value(node) {
      // Every other insertion goes straight through, so the guard cannot be tripped
      // by something this wrapper did not start.
      if (inside) return append.call(this, node);
      inside = true;
      try {
        if (node.classList && node.classList.contains('preview-ghost')) watchFlight(node);
        return append.call(this, node);
      } finally {
        inside = false;
      }
    },
  });
  stubs.push(() => { delete body.appendChild; });
  /** Gives `node` a box, and remembers the getter it had. */
  function place(node, rect) {
    const box = { x: rect.x, y: rect.y, width: rect.width, height: rect.height,
      top: rect.y, left: rect.x, bottom: rect.y + rect.height, right: rect.x + rect.width };
    const had = Object.getOwnPropertyDescriptor(node, 'getBoundingClientRect');
    Object.defineProperty(node, 'getBoundingClientRect', { value: () => box, configurable: true });
    stubs.push(() => {
      if (had) Object.defineProperty(node, 'getBoundingClientRect', had);
      else delete node.getBoundingClientRect;
    });
  }
  /** Tells an `<img>` it is a loaded, square thumbnail. */
  function loaded(image, side = 256) {
    const values = { complete: true, naturalWidth: side, naturalHeight: side };
    const had = {};
    for (const [name, value] of Object.entries(values)) {
      had[name] = Object.getOwnPropertyDescriptor(image, name);
      Object.defineProperty(image, name, { get: () => value, configurable: true });
    }
    stubs.push(() => {
      for (const [name, descriptor] of Object.entries(had)) {
        if (descriptor) Object.defineProperty(image, name, descriptor);
        else delete image[name];
      }
    });
  }
  return {
    place,
    loaded,
    /** Every travelling copy inserted so far, oldest first. */
    flights: () => flights.slice(),
    restore() { for (const undo of stubs.reverse()) undo(); stubs.length = 0; },
  };
}

/** The travelling copy of the photograph, if one is on the screen. */
function ghost(app) {
  return app.window.document.querySelector('.preview-ghost');
}

/** The one step of a flight that says where the photograph is going. */
function poseOf(flight) {
  const pose = flight.steps.find((step) => /scale\(/.test(String(step.transform)));
  assert(pose, `no pose was ever set: the copy was only ever placed, never transformed (${JSON.stringify(flight.steps)})`);
  return pose;
}

/**
 * Checks a recorded pose against where it should have begun.
 *
 * Asserted as geometry rather than as a literal `translate(…) scale(…)` string,
 * because the box is fitted to the photograph's real aspect ratio — which the server,
 * not this test, decides — inside a stage of known size. Three things have to hold:
 * the box is the preview's own box inside the stage, the transform lands the
 * photograph's centre on the tile's centre, and it was scaled down to get there. That
 * is what makes the motion read as one photograph moving rather than one photograph
 * becoming another.
 */
function poseIs(pose, stage, tile) {
  const [dx, dy, scale] = String(pose.transform)
    .match(/translate\((-?[\d.]+)px, (-?[\d.]+)px\) scale\((-?[\d.]+)\)/).slice(1).map(Number);
  return {
    within: pose.left >= stage.x - 0.5 && pose.top >= stage.y - 0.5
      && pose.left + pose.width <= stage.x + stage.width + 0.5
      && pose.top + pose.height <= stage.y + stage.height + 0.5
      // Filling the stage on one axis is what a `contain`-fitted preview looks like,
      // as opposed to the stage's own shape.
      && (Math.abs(pose.width - stage.width) < 0.5 || Math.abs(pose.height - stage.height) < 0.5),
    overTile: Math.abs(pose.left + pose.width / 2 + dx - (tile.x + tile.width / 2)) < 0.5
      && Math.abs(pose.top + pose.height / 2 + dy - (tile.y + tile.height / 2)) < 0.5,
    smaller: scale < 1,
    scale,
    transform: pose.transform,
  };
}

/** A square tile, and a stage big enough to contain anything. */
const TILE_BOX = { x: 100, y: 200, width: 200, height: 200 };
const STAGE_BOX = { x: 500, y: 100, width: 1000, height: 1000 };

/**
 * Puts the client in a world with a layout: this tile at `box`, the stage at
 * `STAGE_BOX`, and the tile's thumbnail loaded.
 */
function layoutWith(app, tiles) {
  const layout = withLayout(app);
  for (const [tile, box] of tiles) {
    // The photograph, not the tile: the travel is measured from the `<img>` the
    // user is looking at, and it is that image the client refuses to fly unless it
    // is loaded and has a box.
    const image = tile.querySelector('img');
    layout.place(tile, box);
    if (image) {
      layout.place(image, box);
      layout.loaded(image);
    }
  }
  layout.place(app.$('lightboxStage'), STAGE_BOX);
  return layout;
}

/**
 * Announces that a rendition of the photograph is on the stage.
 *
 * In a real browser this is the first of the still's candidates arriving — the
 * local thumbnail the grid was already drawing, or the 2048px original behind it,
 * depending on which one the client has asked for by now. Either way it is the
 * event the open travel waits for before handing the screen over from the
 * travelling copy, which is what the animation checks below need.
 *
 * Dispatched rather than stubbed: jsdom has no `HTMLImageElement.decode` at all and
 * never fetches an image, so `load`/`error` on the element is the only channel the
 * client has to hear about either one, and nothing fires on its own. The preview
 * image is never given pixels or a box — it is genuinely "not arrived yet" until
 * this is called, which is the state a real fetch is in.
 */
function renditionArrives(app) {
  app.$('lightboxImage').dispatchEvent(new app.window.Event('load'));
}

/** Announces that a rendition the client asked for could not be produced. */
function renditionFails(app) {
  app.$('lightboxImage').dispatchEvent(new app.window.Event('error'));
}

await check('the photograph flies out of its tile into the preview', async (app) => {
  const tile = app.window.document.querySelector('#grid .tile');
  const layout = layoutWith(app, [[tile, TILE_BOX]]);
  try {
    tile.dispatchEvent(new app.window.MouseEvent('dblclick', { bubbles: true, cancelable: true }));
    await app.settle(60);
    const flown = layout.flights();
    assertEqual(flown.length, 1, 'the preview appeared with nothing travelling — the light change is still sudden');
    const flight = flown[0];
    const pose = poseIs(poseOf(flight), STAGE_BOX, TILE_BOX);
    assert(pose.within, `the travelling copy is not the preview's own box inside the stage (${pose.transform})`);
    assert(pose.overTile, `the travelling copy does not start over the tile it came from (${pose.transform})`);
    assert(pose.smaller, 'nothing was scaled: the preview appeared rather than travelled');
    // The bloom the user asked for, and the travelling copy held invisible until the
    // release, so a late-decoding thumbnail cannot appear mid-flight.
    assertEqual(poseOf(flight).filter, 'brightness(1.28)', 'the travelling photograph is not bloomed');
    assertEqual(poseOf(flight).opacity, '0', 'the travelling photograph starts fully opaque');
    assert(app.$('lightbox').classList.contains('lightbox-entering'),
      'the sharp preview is not held back behind the travelling thumbnail');
    // The preview is still in flight: no bitmap yet, so the travelling copy must hold.
    await app.settle(400);
    assert(flight.node.isConnected, 'the travelling thumbnail was handed over before the preview arrived');
    renditionArrives(app);
    // Long enough for the hand-over's own cross-fade and its removal, which is a
    // separate, shorter motion after the travel itself has landed.
    await app.settle(300);
    assert(!flight.node.isConnected, 'the travelling thumbnail was never handed over');
    assert(!app.$('lightbox').classList.contains('lightbox-entering'),
      'the real preview was left invisible after the hand-over');
    assertEqual(ghost(app), null, 'a travelling photograph was left on screen');
  } finally {
    layout.restore();
  }
});

await check('Space back out plays the travel in reverse', async (app) => {
  const tile = app.window.document.querySelector('#grid .tile');
  const layout = layoutWith(app, [[tile, TILE_BOX]]);
  try {
    tile.dispatchEvent(new app.window.MouseEvent('dblclick', { bubbles: true, cancelable: true }));
    await app.settle(60);
    renditionArrives(app);
    await app.settle(200);
    app.key(' ');
    await app.settle(60);
    const back = layout.flights()[1];
    assert(back, 'the preview vanished instead of travelling back to its tile');
    // The same destination as the way out, played in reverse, with the overlay still
    // on screen so the photograph is not cut off where it stood.
    const pose = poseIs(poseOf(back), STAGE_BOX, TILE_BOX);
    assert(pose.overTile, `the returning photograph does not end at its tile (${pose.transform})`);
    assert(pose.smaller, 'the return is not shrinking back towards the tile');
    assert(back.node.classList.contains('preview-ghost-return'), 'the return is not eased differently');
    assertEqual(app.$('lightbox').hidden, false, 'the overlay was hidden mid-travel');
    assertEqual(app.$('lightbox').classList.contains('is-open'), false,
      'the backdrop did not start fading out');
    await app.settle(500);
    assertEqual(app.$('lightbox').hidden, true, 'the preview stayed on screen after the travel landed');
    assertEqual(ghost(app), null, 'a returning photograph was left on screen');
  } finally {
    layout.restore();
  }
});

await check('a preview with no layout still opens and closes', async (app) => {
  // jsdom has no layout at all, which is the "nothing to fly from" case: the
  // animation has to degrade to appearing rather than fail.
  const tile = app.window.document.querySelector('#grid .tile');
  tile.dispatchEvent(new app.window.MouseEvent('dblclick', { bubbles: true, cancelable: true }));
  await app.settle(200);
  assertEqual(app.$('lightbox').hidden, false, 'the preview did not open without a layout');
  assertEqual(ghost(app), null, 'a travelling photograph appeared with nothing to travel from');
  app.key('Escape');
  await app.settle(200);
  assertEqual(app.$('lightbox').hidden, true, 'the preview did not close without a layout');
});

await check('opening a second preview leaves no photograph behind', async (app) => {
  const tiles = app.window.document.querySelectorAll('#grid .tile');
  const first = tiles[0];
  const second = tiles[1];
  const layout = layoutWith(app, [[first, TILE_BOX], [second, { x: 400, y: 200, width: 200, height: 200 }]]);
  try {
    first.dispatchEvent(new app.window.MouseEvent('dblclick', { bubbles: true, cancelable: true }));
    await app.settle(40);
    assert(layout.flights().length, 'the first preview did not travel at all');
    // Closed mid-flight, which is the case that strands a half-finished copy of a
    // photograph over the grid if the two halves do not cancel each other.
    app.key('Escape');
    await app.settle(20);
    assertEqual(app.window.document.querySelectorAll('.preview-ghost').length, 1,
      'the arriving photograph was not replaced by exactly one returning one');
    await app.settle(500);
    assertEqual(ghost(app), null, 'a photograph was left on screen after the interruption');
    assertEqual(app.$('lightbox').hidden, true, 'the interrupted preview never closed');
  } finally {
    layout.restore();
  }
});

console.log('the preview: what the stage shows when the original is not here yet');

/**
 * The photographs on the first page, in grid order.
 *
 * Read off the default grid rather than by pressing the media chip: the media
 * filter is a route of its own with checks of its own, and a preview check that
 * cannot run when that route stalls would be testing two things at once. A tile
 * says what it is — a clip's is the only one carrying a play glyph — so a
 * photograph is a tile without one.
 */
function stillTiles(app) {
  return [...app.window.document.querySelectorAll('#grid .tile')]
    .filter((tile) => !tile.querySelector('.tile-play'));
}

/**
 * Two photographs that are next to each other in the grid, for a paging check.
 *
 * Adjacent in the DOM is adjacent in the queue — the first page is rendered from
 * offset zero in order — so the tile after this pair's first is the one a right
 * arrow lands on.
 */
function adjacentStills(app) {
  const tiles = [...app.window.document.querySelectorAll('#grid .tile')];
  for (let i = 0; i + 1 < tiles.length; i += 1) {
    if (!tiles[i].querySelector('.tile-play') && !tiles[i + 1].querySelector('.tile-play')) {
      return [tiles[i], tiles[i + 1]];
    }
  }
  return null;
}

await check('a preview that has not arrived shows a local rendition, not an empty stage', async (app) => {
  // The defect this pins. The stage used to be blank until the 2048px preview came
  // down from iCloud — and stayed blank for good when it never did, which is what an
  // optimised library with downloads on looks like while the original is fetched.
  // Every tile already holds a decoded local rendition, so the first thing in the
  // stage has to be that.
  const [tile] = stillTiles(app);
  assert(tile, 'the first page has no photograph on it');
  await openLightboxOn(app, tile);
  const id = tile.dataset.id;
  const encoded = app.window.encodeURIComponent(id);
  const image = app.$('lightboxImage');
  const src = image.getAttribute('src');

  // The first thing asked for is a local rendition of *this* photograph, not the
  // 2048px original that may have to come down from iCloud first.
  assert(/^\/api\/photo\/.+\/thumbnail\?size=\d+$/.test(src),
    `the stage is not showing a local rendition of the photo: ${src}`);
  assert(src.includes(encoded), `the local rendition belongs to another photo: ${src}`);
  assertEqual(app.$('lightboxFallback').hidden, true, 'the fallback sentence is up over a photo we can draw');

  // It is on the stage as soon as it decodes, and the original is asked for behind
  // it — a local rendition is a step, not the destination.
  renditionArrives(app);
  assertEqual(image.hidden, false, 'the stage was left empty while the preview was pending');
  assertEqual(image.getAttribute('src'), `/api/photo/${encoded}/preview?size=2048`,
    'the original was never asked for behind the local rendition');
});

await check('a preview that fails leaves a rendition on the stage, not a blank one', async (app) => {
  // The other half: the 2048px request is refused. What was on the stage a moment
  // ago is the honest answer, and it must not be replaced by nothing.
  const [tile] = stillTiles(app);
  assert(tile, 'the first page has no photograph on it');
  await openLightboxOn(app, tile);
  const image = app.$('lightboxImage');
  const local = image.getAttribute('src');

  renditionArrives(app);   // the local rendition, which raises the original
  renditionFails(app);     // …and the original cannot be produced

  assertEqual(image.getAttribute('src'), local, 'the stage did not fall back to the rendition it had');
  assertEqual(app.$('lightboxFallback').hidden, true,
    'the fallback sentence is up while a rendition is on the stage');
  // And it really is the thing on the stage, not a request that went nowhere.
  renditionArrives(app);
  assertEqual(image.hidden, false, 'the photograph vanished when the original could not be produced');
});

await check('the fallback sentence is only reached when nothing can be drawn at all', async (app) => {
  const [tile] = stillTiles(app);
  assert(tile, 'the first page has no photograph on it');
  await openLightboxOn(app, tile);
  const image = app.$('lightboxImage');
  const fallback = app.$('lightboxFallback');

  // The local ladder, then the original: nothing on this Mac can draw the
  // photograph and Photos cannot produce it either.
  for (let attempt = 0; attempt < 3; attempt += 1) renditionFails(app);

  assertEqual(image.hidden, true, 'the <img> is still on the stage with nothing in it');
  assertEqual(fallback.hidden, false, 'nothing was said about a photograph that cannot be drawn');
  assert(/Preview unavailable/.test(fallback.textContent),
    `the fallback does not read as a fallback: ${fallback.textContent}`);
});

await check('paging shows the next photograph’s own rendition rather than a blank stage', async (app) => {
  // The reader's second symptom: with the original unavailable, every arrow key
  // repainted the same empty rectangle, so the arrows looked dead. Paging has to put
  // the *next* photo's local rendition up, and it must be a local one — the point is
  // that it arrives without waiting for iCloud.
  const pair = adjacentStills(app);
  assert(pair, 'the first page has no two adjacent photographs on it');
  const [first, second] = pair;
  await openLightboxOn(app, first);
  const image = app.$('lightboxImage');

  app.key('ArrowRight');
  await app.settle(60);

  // The pair is found anywhere on the page, so the position it moves *to* is the
  // tile's own grid index plus two, not a literal.
  const arrived = Number(first.dataset.index) + 2;
  assert(app.$('lightboxPosition').textContent.startsWith(`${arrived} of`),
    `the lightbox did not move: ${app.$('lightboxPosition').textContent}`);
  assertEqual(image.hidden, false, 'paging left the stage empty');
  assertEqual(app.$('lightboxFallback').hidden, true, 'paging put the fallback sentence up instead of a photo');
  const src = image.getAttribute('src');
  assert(/^\/api\/photo\/.+\/thumbnail\?size=\d+$/.test(src), `paging did not show a local rendition: ${src}`);
  assert(src.includes(app.window.encodeURIComponent(second.dataset.id)),
    `the stage is not showing the photo that was paged to: ${src}`);
});

console.log('the preview: the panel, and zoom');

await check('the preview panel offers the hand-off to Photos, and not the chips that moved', async (app) => {
  // The three chips this replaced each had another way in — "Show in All Photos" is
  // the tile's hover tool and a menu item, "Show Similar Photos" is the menu item,
  // and selecting is a click on the tile — while the one action that leaves the app
  // had no control on this surface at all. Asserted on the ids first, because a chip
  // that survives under a new id is the regression this is here to catch.
  assertEqual(app.$('lightboxAllPhotos'), null, 'the "Show in All Photos" chip is still in index.html');
  assertEqual(app.$('lightboxSimilarPhotos'), null, 'the "Show Similar Photos" chip is still in index.html');
  assertEqual(app.$('lightboxSelect'), null, 'the Select chip is still in index.html');
  assert(app.$('lightboxOpenInPhotos'), 'the panel has no Photos hand-off');

  const sent = interceptReveals(app);
  const [tile] = stillTiles(app);
  assert(tile, 'the first page has no photograph on it');
  await openLightboxOn(app, tile);
  app.click('lightboxOpenInPhotos');
  await app.settle(120);

  assertEqual(sent.length, 1, `the hand-off asked Photos for ${sent.length} photos`);
  assertEqual(sent[0].id, tile.dataset.id, 'the hand-off did not name the photograph on the stage');
});

/** The still's own transform, as the three numbers `zoomTo` writes. */
function zoomOf(app) {
  const raw = app.$('lightboxImage').style.transform || '';
  const scale = Number((raw.match(/scale\(([\d.]+)\)/) || [])[1] || 1);
  const translate = (raw.match(/translate\((-?[\d.]+)px, (-?[\d.]+)px\)/) || []).slice(1).map(Number);
  return { scale, x: translate[0] || 0, y: translate[1] || 0 };
}

/**
 * Where the photograph's own centre is on screen.
 *
 * The still is `object-fit: contain` inside the stage-sized element, so its pixels
 * are centred in that box whatever their shape and whatever the magnification.
 */
function zoomCentre(app, box) {
  const zoom = zoomOf(app);
  return { x: box.x + zoom.x + zoom.scale * box.width / 2,
           y: box.y + zoom.y + zoom.scale * box.height / 2 };
}

/** Where a point of the stage's own box ends up once the still is transformed. */
function zoomLands(app, box, point) {
  const zoom = zoomOf(app);
  return { x: box.x + zoom.x + zoom.scale * point.x, y: box.y + zoom.y + zoom.scale * point.y };
}

/**
 * The first photograph on the page the server reports a shape for, matching `want`.
 *
 * The zoom checks need to know what shape they are working with: an anchor has to be
 * a point *on* the photograph, and a pan needs the magnification to have left the
 * axis somewhere to go, both of which depend on the row's own width and height rather
 * than on anything the grid holds. Skipped rather than faked when this page has none
 * of the shape asked for — asserting about a fixture is not asserting about the app.
 */
async function stillOfShape(app, want) {
  for (const tile of stillTiles(app).slice(0, 8)) {
    const response = await fetch(`${base}/api/photo/${encodeURIComponent(tile.dataset.id)}`);
    const row = (await response.json()).photo || {};
    if (row.width > 0 && row.height > 0 && want(row)) return { tile, row };
  }
  return undefined;
}

/** A landscape photograph: the band across a square stage's middle is on its pixels. */
const landscapeStill = (app) => stillOfShape(app, (row) => row.width > row.height);

/**
 * A portrait photograph that is not a sliver.
 *
 * `STAGE_BOX` is square, so a portrait photo's fitted width is well under the stage's
 * and its height is exactly it: the vertical axis can pan as soon as it is magnified,
 * and the horizontal one only once the magnification has carried that fitted width
 * past the stage's. The three steps the check takes get there for anything taller
 * than about 1:2.7, and 1:2.5 is the bound here so the assertion cannot come down to
 * which photograph the page happened to start with.
 */
const portraitStill = (app) => stillOfShape(app,
  (row) => row.height > row.width && row.width / row.height > 0.4);

/** A pinch (a wheel with `ctrlKey`) at a point of the stage. */
function pinch(app, point, deltaY = -240) {
  app.$('lightboxStage').dispatchEvent(new app.window.WheelEvent('wheel', {
    deltaY, ctrlKey: true, clientX: point.x, clientY: point.y, bubbles: true, cancelable: true,
  }));
}

/** A two-finger scroll, or a mouse wheel: no modifier, and both deltas are meaningful. */
function scrollStage(app, { deltaX = 0, deltaY = 0 } = {}) {
  app.$('lightboxStage').dispatchEvent(new app.window.WheelEvent('wheel', {
    deltaX, deltaY, clientX: STAGE_BOX.x + STAGE_BOX.width / 2, clientY: STAGE_BOX.y + STAGE_BOX.height / 2,
    bubbles: true, cancelable: true,
  }));
}

await check('a pinch magnifies the photograph about the point under the fingers', async (app) => {
  const subject = await landscapeStill(app);
  if (!subject) return; // this page happens to hold no landscape photograph
  const layout = layoutWith(app, []);
  try {
    await openLightboxOn(app, subject.tile);
    // A point of the stage that is on the photograph and off its centre: the centre
    // would hold still under any scale, so it is the only anchor that tests the
    // arithmetic — and it is also the only one where the clamp (which stops the
    // photograph sliding off the stage) never has to intervene.
    const local = { x: STAGE_BOX.width * 0.7, y: STAGE_BOX.height * 0.5 };
    const at = { x: STAGE_BOX.x + local.x, y: STAGE_BOX.y + local.y };

    pinch(app, at);
    const zoomed = zoomOf(app);
    assert(zoomed.scale > 1, `a pinch did not magnify the photograph (scale ${zoomed.scale})`);

    // The point under the fingers is the point that stays under them.
    const landed = zoomLands(app, STAGE_BOX, local);
    assert(Math.abs(landed.x - at.x) < 1.5 && Math.abs(landed.y - at.y) < 1.5,
      `the photograph slid out from under the gesture (${JSON.stringify(landed)} vs ${JSON.stringify(at)})`);

    // And only the photograph moved with it: the overlay, the stage the reader is
    // pointing at, and the panel are all where they were.
    assertEqual(app.$('lightbox').style.transform, '', 'the overlay was magnified too');
    assertEqual(app.$('lightboxStage').style.transform, '', 'the stage was magnified too');
    assertEqual(app.window.document.querySelector('.lightbox-meta').style.transform, '',
      'the panel was magnified too');
  } finally {
    layout.restore();
  }
});

await check('the keys zoom about the centre, and 0 returns to fit', async (app) => {
  const [tile] = stillTiles(app);
  assert(tile, 'the first page has no photograph on it');
  const layout = layoutWith(app, []);
  try {
    await openLightboxOn(app, tile);
    const before = zoomCentre(app, STAGE_BOX);
    app.key('=');
    await app.settle(30);
    assert(zoomOf(app).scale > 1, 'the zoom-in key did nothing');

    // About the *centre*: the photograph's own centre must not drift. (The
    // element's translation is not the thing to assert — a centre-anchored zoom
    // writes one — which is why this reads the geometry the reader sees.)
    const after = zoomCentre(app, STAGE_BOX);
    assert(Math.abs(after.x - before.x) < 1.5 && Math.abs(after.y - before.y) < 1.5,
      `the centred step moved the photograph (${JSON.stringify(before)} → ${JSON.stringify(after)})`);

    app.key('0');
    await app.settle(30);
    assertEqual(zoomOf(app).scale, 1, '0 did not return the photograph to fit');
    assertEqual(app.$('lightboxStage').classList.contains('is-zoomed'), false,
      'the stage still offers a pan cursor at fit');

    // ⌘= is the browser's page zoom and this client must not take it.
    app.key('=', { metaKey: true });
    await app.settle(30);
    assertEqual(zoomOf(app).scale, 1, 'the client claimed the browser page-zoom shortcut');
  } finally {
    layout.restore();
  }
});

await check('a drag pans a magnified photograph instead of paging to the next one', async (app) => {
  const subject = await landscapeStill(app);
  if (!subject) return; // this page happens to hold no landscape photograph
  const layout = layoutWith(app, []);
  try {
    await openLightboxOn(app, subject.tile);
    const image = app.$('lightboxImage');
    const before = app.$('lightboxPosition').textContent;
    app.key('='); // one step, about the centre: a known pose to pan from
    await app.settle(30);
    const zoomed = zoomOf(app);
    assert(zoomed.scale > 1, 'nothing to pan');

    const pointer = (type, x, y) => image.dispatchEvent(new app.window.PointerEvent(type, {
      pointerId: 1, button: 0, clientX: x, clientY: y, bubbles: true, cancelable: true,
    }));
    pointer('pointerdown', 900, 600);
    pointer('pointermove', 940, 630);
    pointer('pointerup', 940, 630);
    // The pan is the drag's own delta, to within the arithmetic's own precision:
    // these are float transforms, and asserting the last bit of one is asserting
    // about the double, not about the drag.
    const panned = zoomOf(app);
    assert(Math.abs(panned.x - (zoomed.x + 40)) < 0.01,
      `the drag did not pan the photograph sideways (${panned.x} vs ${zoomed.x + 40})`);

    // Downwards only once the photograph is taller than the stage: below that the
    // clamp centres it, which is what "the photograph can never be panned off the
    // stage" means, and it is the answer to the same drag. Asserted either way
    // rather than skipped — both are behaviour a regression could break.
    const aspect = subject.row.width / subject.row.height;
    const tallerThanStage = (STAGE_BOX.width / aspect) * zoomed.scale > STAGE_BOX.height + 1;
    if (tallerThanStage) {
      assert(Math.abs(panned.y - (zoomed.y + 30)) < 0.01,
        `the drag did not pan the photograph down (${panned.y} vs ${zoomed.y + 30})`);
    } else {
      assertEqual(panned.y, zoomed.y, 'an axis with no slack was panned anyway');
    }

    // Letting go of a drag is not a request for the next photograph — and neither is
    // any other click on the picture, which is the other half of "only the arrows
    // navigate" (`zoomPanEnd` has nothing to suppress, because nothing on the stage
    // pages on a click).
    image.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    await app.settle(60);
    assertEqual(app.$('lightboxPosition').textContent, before, 'letting go of a pan paged the overlay');
  } finally {
    layout.restore();
  }
});

await check('paging puts the next photograph back at fit', async (app) => {
  const pair = adjacentStills(app);
  if (!pair) return; // this page happens to hold no two adjacent photographs
  const layout = layoutWith(app, []);
  try {
    await openLightboxOn(app, pair[0]);
    pinch(app, { x: STAGE_BOX.x + 300, y: STAGE_BOX.y + 300 });
    assert(zoomOf(app).scale > 1, 'the pinch did not magnify anything to reset');
    app.key('ArrowRight');
    await app.settle(60);
    // The next photo's rendition, not the previous photo's magnification: a
    // magnified rect carried onto it would show a corner with nothing to explain it.
    assertEqual(zoomOf(app).scale, 1, 'the magnification was carried onto the next photograph');
    assertEqual(zoomOf(app).x, 0, 'the magnification was carried onto the next photograph');
  } finally {
    layout.restore();
  }
});

await check('a scroll moves a magnified photograph, in the direction it names', async (app) => {
  // The other half of the wheel: once there is somewhere to go, a two-finger scroll
  // is a pan rather than a magnifier — down the photograph for a scroll down, right
  // along it for a scroll right, which is the same direction word the drag and the
  // pan cursor use.
  const subject = await portraitStill(app);
  if (!subject) return; // this page happens to hold no portrait photograph
  const layout = layoutWith(app, []);
  try {
    await openLightboxOn(app, subject.tile);
    // Three steps, not one: a portrait photo needs its fitted width magnified past
    // the square stage's before that axis has anywhere to pan to (see `portraitStill`).
    app.key('=');
    app.key('=');
    app.key('=');
    await app.settle(30);
    const zoomed = zoomOf(app);
    const position = app.$('lightboxPosition').textContent;

    scrollStage(app, { deltaY: 60 });
    assertEqual(zoomOf(app).scale, zoomed.scale, 'a scroll changed the magnification');
    assert(Math.abs(zoomOf(app).y - (zoomed.y - 60)) < 0.01,
      `a scroll down did not move down the photograph (${zoomOf(app).y} vs ${zoomed.y - 60})`);
    assert(Math.abs(zoomOf(app).x - zoomed.x) < 0.01, 'a vertical scroll moved the photograph sideways');

    scrollStage(app, { deltaX: 60 });
    assert(Math.abs(zoomOf(app).x - (zoomed.x - 60)) < 0.01,
      `a scroll right did not move right along the photograph (${zoomOf(app).x} vs ${zoomed.x - 60})`);
    assertEqual(app.$('lightboxPosition').textContent, position, 'scrolling paged the overlay');
  } finally {
    layout.restore();
  }
});

await check('a scroll down at fit leaves the preview, and a nudge does not', async (app) => {
  // At fit there is nothing left to move, so the scroll down is the gesture that puts
  // the preview away — accumulated over one gesture, because a trackpad reports a
  // deliberate swipe as a stream of small deltas and a preview that closed on any one
  // of them would close on an accident.
  const [tile] = stillTiles(app);
  assert(tile, 'the first page has no photograph on it');
  const layout = layoutWith(app, []);
  try {
    await openLightboxOn(app, tile);
    scrollStage(app, { deltaY: 20 });
    await app.settle(60);
    assertEqual(app.$('lightbox').hidden, false, 'a nudge down closed the preview');
    assertEqual(zoomOf(app).scale, 1, 'a plain scroll magnified the photograph');

    // A gesture that ends restarts the swipe: the nudge above must not be sitting in
    // wait for the next one to complete it.
    await app.settle(250);
    scrollStage(app, { deltaY: 60 });
    await app.settle(60);
    assertEqual(app.$('lightbox').hidden, false, 'a short scroll closed the preview');

    scrollStage(app, { deltaY: 60 });
    scrollStage(app, { deltaY: 60 });
    await app.settle(500);
    assertEqual(app.$('lightbox').hidden, true, 'a swipe down did not leave the preview');
  } finally {
    layout.restore();
  }
});

await check('a clip is not magnified — its transport owns its own gestures', async (app) => {
  // "Zoom only the photo" cuts both ways: a wheel over a clip's picture is next to
  // its scrub bar and its volume, and a magnified `<video>` would drag those with it.
  const clip = [...app.window.document.querySelectorAll('#grid .tile')]
    .find((tile) => tile.querySelector('.tile-play'));
  if (!clip) return; // this page happens to hold no clip
  const layout = layoutWith(app, []);
  try {
    await openLightboxOn(app, clip);
    assertEqual(app.$('lightboxVideo').hidden, false, 'the clip did not reach the stage');
    pinch(app, { x: STAGE_BOX.x + 300, y: STAGE_BOX.y + 300 });
    assertEqual(zoomOf(app).scale, 1, 'a clip was magnified');
  } finally {
    layout.restore();
  }
});

console.log('similar groups: the same pointer model as the grid');

/**
 * Opens the Similar Groups view and returns its first card.
 *
 * Polled rather than waited a fixed time: on a cold start the client has to load
 * its status and start the album index before the group view has anything to show,
 * and how long that takes depends on the library. A fixed wait is either too short
 * (a flake that looks like a regression) or needlessly long on every other run.
 */
async function openGroups(app) {
  app.click('groupsButton');
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await app.settle(250);
    const card = app.window.document.querySelector('#groupsList .group-card');
    if (card && card.querySelector('.group-cell')) return card;
  }
  throw new Error('the group view never showed a group with members');
}

/** The member cell at `index` of the first group. */
function cellAt(app, card, index) {
  const cell = card.querySelector(`.group-cell[data-index="${index}"]`);
  assert(cell, `no cell at index ${index}`);
  return cell;
}

await check('one click on a group cell selects instead of previewing', async (app) => {
  const card = await openGroups(app);
  const cell = cellAt(app, card, 2);
  cell.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await app.settle(200);
  assertEqual(app.$('lightbox').hidden, true, 'a single click opened the preview');
  assert(cell.classList.contains('selected'), 'the clicked cell is not marked as selected');
  assertEqual(cell.getAttribute('aria-pressed'), 'true', 'the cell was not announced as selected');
  assert(/1 asset selected/.test(app.$('selectionSummary').textContent),
    `the selection bar did not count it: ${app.$('selectionSummary').textContent}`);
});

await check('double click on a group cell opens the preview', async (app) => {
  const card = await openGroups(app);
  const cell = cellAt(app, card, 1);
  cell.dispatchEvent(new app.window.MouseEvent('dblclick', { bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, false, 'a double click did not open the preview');
});

await check('Space on a group cell toggles the preview', async (app) => {
  const card = await openGroups(app);
  const cell = cellAt(app, card, 1);
  cell.dispatchEvent(new app.window.KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, false, 'Space did not open the preview');

  app.key(' ');
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, true, 'Space did not close the preview');
});

await check('a group cell is focusable without being a button, so Space reaches it', async (app) => {
  // The regression this pins. The cell used to be a `<button>`, and WebKit does not
  // move focus to a button when it is clicked — so the cell never held focus after
  // the click that selected it, and Space, which goes to whatever *is* focused, never
  // reached the cell's keydown handler.
  //
  // jsdom cannot reproduce that: it focuses a `<button>` on click, which is the one
  // behaviour WebKit withholds. So the test asserts the invariant that keeps the cell
  // on the keyboard path — it is focusable, and it is not a native button, which is
  // the element whose focus-on-click the grid tile deliberately avoids. Asserting the
  // observed focus here would pass on the broken build and catch nothing.
  const card = await openGroups(app);
  const cell = cellAt(app, card, 1);
  assertEqual(cell.tagName, 'DIV', 'the cell is a native button again, so a click will not focus it');
  assertEqual(cell.tabIndex, 0, 'the cell cannot hold focus');
  assertEqual(cell.getAttribute('role'), 'button', 'the cell is no longer announced as a button');

  // Focusable in practice, and Space then reaches its own handler rather than
  // stopping at the document.
  cell.focus({ preventScroll: true });
  assertEqual(app.window.document.activeElement, cell, 'focusing the cell did not take');
  app.window.document.activeElement.dispatchEvent(new app.window.KeyboardEvent('keydown',
    { key: ' ', bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, false, 'Space on a focused cell did not open the preview');
});

await check('Space on the same cell again opens it again', async (app) => {
  // The toggle has to be a toggle, not a one-shot. This is the case a
  // `live.queue === rows` identity check gets wrong when the queue is rebuilt per
  // call, which is exactly what a group strip does.
  const card = await openGroups(app);
  const cell = cellAt(app, card, 1);
  cell.dispatchEvent(new app.window.KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
  await app.settle(300);
  app.key(' ');
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, true, 'the preview did not close');
  cell.dispatchEvent(new app.window.KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, false, 'the preview did not come back');
});

await check('shift-clicking a group cell selects the range between', async (app) => {
  const card = await openGroups(app);
  const first = cellAt(app, card, 1);
  const last = cellAt(app, card, 4);
  first.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await app.settle(150);
  last.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true, shiftKey: true }));
  await app.settle(250);

  // "assets": the noun follows the media filter, and the default is "all", which
  // admits clips as well as photographs. Group *members* are always stills today,
  // but the bar counts what the selection resolved to rather than what a group is.
  const summary = app.$('selectionSummary').textContent;
  assert(/4 assets selected/.test(summary), `the range selected the wrong span: ${summary}`);
  for (const index of [1, 2, 3, 4]) {
    assert(cellAt(app, card, index).classList.contains('selected'),
      `rank ${index + 1} is in the range but is not marked`);
  }
  assert(!cellAt(app, card, 5).classList.contains('selected'), 'the range ran past its end');
});

await check("a group cell's heart is the same control as a tile's", async (app) => {
  // The heart used to be a `<span>` in a group strip that appeared only once a
  // photo was *already* a favourite: it could report the flag but never set it,
  // while the grid tile's heart set it from the photo. One promise, two different
  // controls. This writes to the library, so it restores the flag afterwards.
  const card = await openGroups(app);
  const cell = cellAt(app, card, 1);
  const heart = cell.querySelector('.group-heart');
  assert(heart, 'the group cell has no heart');
  assertEqual(heart.tagName, 'BUTTON', 'the group heart is not a control');

  // Present whether or not the photo is a favourite: an outline heart is the
  // offer. A node that only exists once the flag is set cannot offer anything.
  assertEqual(heart.getAttribute('aria-pressed'), 'false',
    'a photo that is not a favourite has no heart to press');

  const id = cell.dataset.id;
  const setFavorite = (favorite) => fetch(`${base}/api/favorites`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids: [id], favorite }),
  });
  try {
    heart.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    await app.settle(900);
    const after = app.window.document.querySelector(
      `#groupsList .group-cell[data-id="${app.window.CSS.escape(id)}"] .group-heart`);
    assert(after, 'the heart vanished from the cell it was pressed on');
    assertEqual(after.getAttribute('aria-pressed'), 'true',
      'pressing the heart on a group cell did not make it a favourite');

    // And pressing again takes it back, which is the toggle rather than a set.
    after.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    await app.settle(900);
    assertEqual(after.getAttribute('aria-pressed'), 'false',
      'pressing the heart a second time did not undo it');
  } finally {
    await setFavorite(false);
    await app.settle(600);
  }
});

await check("pressing a group cell's heart does not also select the cell", async (app) => {
  // The cell is a click target in its own right, so a heart that did not stop
  // propagation would select the photo as a side effect of favouriting it.
  const card = await openGroups(app);
  const cell = cellAt(app, card, 2);
  const id = cell.dataset.id;
  const setFavorite = (favorite) => fetch(`${base}/api/favorites`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids: [id], favorite }),
  });
  try {
    cell.querySelector('.group-heart')
      .dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    await app.settle(400);
    assert(!cell.classList.contains('selected'),
      'the heart press selected the cell as well as favouriting it');
  } finally {
    await setFavorite(false);
    await app.settle(600);
  }
});

await check("Delete in a group cell's menu destroys that member and only that member", async (app) => {
  const sent = interceptDeletes(app);
  const card = await openGroups(app);
  const before = [...card.querySelectorAll('.group-cell')].map((cell) => cell.dataset.id);
  assert(before.length >= 3, 'the group is too small for this test');
  const target = before[1];

  // The strip's own context menu, which is the only way a group member can be
  // destroyed while the group view owns the screen.
  const cell = cellAt(app, card, 1);
  cell.dispatchEvent(new app.window.MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
  await app.settle(250);
  const items = [...app.window.document.querySelectorAll('#tileMenu .menu-item')];
  const destroy = items.find((item) => /^Delete/.test(item.textContent));
  assert(destroy, `no Delete item in the group cell menu: ${items.map((i) => i.textContent).join(' | ')}`);
  destroy.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await app.settle(600);

  assertEqual(sent.length, 1, `the strip's Delete destroyed nothing (${sent.length} requests)`);
  assertEqual(sent[0].ids, [target], 'the strip destroyed something other than the member');
});

console.log('photo menu: only actions on the photo or the library');

/** Opens the context menu on `tile` and returns its items, as plain records. */
async function openMenuOn(app, tile) {
  tile.dispatchEvent(new app.window.MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
  await app.settle(250);
  assert(!app.$('tileMenuLayer').hidden, 'the menu did not open');
  return [...app.$('tileMenu').children].map((node) => {
    if (node.getAttribute('role') === 'separator') return { separator: true };
    // The label is the button's own first text node and the hint is a child span,
    // so reading `textContent` would run the two together ("Delete1 photo").
    const hintNode = node.querySelector('.menu-hint');
    return {
      label: node.firstChild ? node.firstChild.textContent : '',
      hint: hintNode ? hintNode.textContent : '',
      disabled: node.getAttribute('aria-disabled') === 'true',
    };
  });
}

/** The labels of a menu, separators dropped. */
const labelsOf = (items) => items.filter((i) => !i.separator).map((i) => i.label);

/**
 * Whether a tile is drawn as a favourite.
 *
 * The heart, and its `aria-pressed`, which is what the tile announces the state
 * with. This replaced a `.tile-flag.favorite` lookup when the star chip and the
 * padlock were dropped from the tile's gutter — and that stale selector was the
 * worse kind of bug, because it matched nothing, so every "find me a plain
 * photo" expression quietly returned the first tile in the grid and the tests
 * using it stopped checking what they claimed to.
 */
const isFavouriteTile = (tile) => {
  const heart = tile.querySelector('.tile-heart');
  return Boolean(heart) && heart.getAttribute('aria-pressed') === 'true';
};

/** The menu item node whose label is exactly `label`. */
function menuItemNode(app, label) {
  const node = [...app.$('tileMenu').children]
    .find((n) => n.getAttribute('role') === 'menuitem'
      && n.firstChild && n.firstChild.textContent === label);
  assert(node, `no menu item labelled "${label}"`);
  return node;
}

await check('favourite protection is not offered as a control', async (app) => {
  // The guarantee is unconditional, so there is nothing to switch and nothing to
  // count. Asserted on the ids *and* on the visible text, because a control that
  // survives under a new id is the failure this is here to catch.
  assertEqual(app.$('protectFavorites'), null, 'the Protect Favorites switch is still in the panel');
  assertEqual(app.$('protectFavoritesOption'), null, 'its label is still in the panel');
  assertEqual(app.$('protectedCount'), null, 'the protected count is still in the panel');
  assertEqual(app.$('protectedCountWrap'), null, 'its wrapper is still in the panel');
  const panel = app.window.document.querySelector('.controls-row');
  assert(!/Protect Favorites/.test(panel.textContent),
    'the words "Protect Favorites" are still on screen');
  assert(!/protected from deletion/.test(panel.textContent),
    'the protected count is still on screen');
});

await check('a favourite says it is protected, and cannot be told otherwise', async (app) => {
  // Where the guarantee moved to: onto the photo it is about. The old switch made
  // this conditional on server state, and the tooltip had a second, contradicting
  // wording for when it was off — so "protected" had to be checked against a
  // setting the user could not see from here.
  const tiles = [...app.window.document.querySelectorAll('#grid .tile')];
  for (const tile of tiles) {
    const heart = tile.querySelector('.tile-heart');
    if (!heart || heart.getAttribute('aria-pressed') !== 'true') continue;
    assert(/protected from deletion/.test(heart.getAttribute('title') || ''),
      'a favourite heart does not say it is protected');
    assert(/protected from deletion/.test(tile.getAttribute('aria-label') || ''),
      'a favourite tile does not announce that it is protected');
    return;
  }
  // No favourite on this page of somebody's real library: nothing to assert, and
  // inventing a photo to assert about would be asserting about the fixture.
});

await check('the menu offers only actions, not selection', async (app) => {
  const items = await openMenuOn(app, app.window.document.querySelector('#grid .tile'));
  assertEqual(labelsOf(items), ['Show in All Photos', 'Show Similar Photos', 'Open in Photos',
    'Favourite', 'Delete'],
  'the menu is not the set of actions that were asked for');
});

await check('the favourite is one item, and it is never greyed out', async (app) => {
  const d = app.window.document;
  const tiles = [...d.querySelectorAll('#grid .tile')];

  // A plain photo offers "Favourite" and nothing else — the old menu also carried a
  // "Remove from Favourites" here, disabled, and a disabled item on a favourite
  // reads as "something is wrong" rather than "not applicable".
  const plain = tiles.find((t) => !isFavouriteTile(t));
  const plainItems = await openMenuOn(app, plain);
  assertEqual(labelsOf(plainItems).filter((l) => /Favourite/.test(l)), ['Favourite'],
    'a plain photo offers more than the one favourite item');
  assertEqual(plainItems.find((i) => i.label === 'Favourite').disabled, false,
    'the favourite toggle was greyed out on a plain photo');

  // A favourite offers only the other wording — one item, naming what it will do.
  const favourite = tiles.find((t) => isFavouriteTile(t));
  if (!favourite) return; // this library page happens to hold no favourite
  const favItems = await openMenuOn(app, favourite);
  assertEqual(labelsOf(favItems).filter((l) => /Favourite/.test(l)), ['Remove from Favourites'],
    'a favourite does not offer exactly one favourite item');
  assertEqual(favItems.find((i) => i.label === 'Remove from Favourites').disabled, false,
    'the favourite toggle was greyed out on a favourite');
});

await check('Show Similar Photos is greyed out for a photograph that has none', async (app) => {
  // Which photographs have a group is a fact about the grouping pass, not about the
  // row — nothing the grid holds names a group — so the item is corrected from
  // `GET /api/photo/{id}/similar` once the menu is up. Ask the server the same
  // question here and work with what it says about the photographs actually on this
  // page, rather than inventing one to assert about.
  const tiles = [...app.window.document.querySelectorAll('#grid .tile')].slice(0, 12);
  const answers = await Promise.all(tiles.map(async (tile) => {
    const response = await fetch(`${base}/api/photo/${encodeURIComponent(tile.dataset.id)}/similar`);
    return { tile, answer: await response.json() };
  }));
  const lone = answers.find(({ answer }) => answer.analyzed === true && !answer.groupId);
  const grouped = answers.find(({ answer }) => answer.groupId);

  if (lone) {
    const items = await openMenuOn(app, lone.tile);
    // The lookup is a round trip that starts after the menu is on screen.
    await app.settle(400);
    const item = items.find((entry) => entry.label === 'Show Similar Photos');
    assert(item, 'the menu no longer offers similar photos at all');
    assertEqual(item.disabled, true, 'a photograph with no similar photos still offers the item');
    assertEqual(item.hint, 'none found', 'the greyed-out item does not say why');
    // Greyed out *and* inert: the label is the promise, the click is the behaviour.
    menuItemNode(app, 'Show Similar Photos')
      .dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    await app.settle(300);
    assertEqual(app.$('groupsView').hidden, true, 'the greyed-out item ran anyway');
  }

  if (grouped) {
    const items = await openMenuOn(app, grouped.tile);
    await app.settle(400);
    const item = items.find((entry) => entry.label === 'Show Similar Photos');
    assert(item, 'the menu no longer offers similar photos at all');
    assertEqual(item.disabled, false, 'a photograph that has a group was greyed out');
    assertEqual(item.hint, '', 'a photograph that has a group is carrying the "none found" hint');
  }
});

await check('the favourite item makes the photo a favourite', async (app) => {
  // This writes to the library, so it restores the flag in a finally block.
  const d = app.window.document;
  const tile = [...d.querySelectorAll('#grid .tile')].find((t) => !isFavouriteTile(t));
  assert(tile, 'no plain tile to work with');
  const id = tile.dataset.id;
  const setFavorite = async (favorite) => {
    await fetch(`${base}/api/favorites`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ids: [id], favorite }),
    });
  };
  try {
    await openMenuOn(app, tile);
    menuItemNode(app, 'Favourite')
      .dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    await app.settle(900);

    // The heart is the tile's only favourite mark now — the star chip and the
    // padlock that shared the right-hand gutter are gone — so this reads the
    // heart. `aria-pressed` is what the change is actually asserted on: the
    // filled glyph is drawn in CSS, and a test that read the class would be
    // asserting on how it looks rather than on what it says.
    const after = d.querySelector(`#grid .tile[data-id="${app.window.CSS.escape(id)}"]`);
    const heart = after && after.querySelector('.tile-heart');
    assert(heart, 'the tile has no heart to mark the favourite with');
    assertEqual(heart.getAttribute('aria-pressed'), 'true',
      'clicking the menu item did not mark the photo as a favourite');
  } finally {
    await setFavorite(false);
    await app.settle(600);
  }
});

await check('the delete item is Delete, and its hint says what it will destroy', async (app) => {
  const items = await openMenuOn(app, app.window.document.querySelector('#grid .tile'));
  const del = items.find((i) => i.label === 'Delete');
  assert(del, 'no Delete item');
  assertEqual(del.hint, '1 asset', 'the hint does not say what will be covered');
  assertEqual(del.disabled, false, 'Delete is greyed out');
  assertEqual(labelsOf(items).filter((l) => /delete list/i.test(l)), [],
    'the menu still offers to take photos back out of a delete list');
});

await check('Delete in the menu destroys the photo it was opened on', async (app) => {
  const sent = interceptDeletes(app);
  const target = app.tileIds()[0];
  const tile = app.window.document.querySelector(`#grid .tile[data-id="${app.window.CSS.escape(target)}"]`);
  await openMenuOn(app, tile);
  menuItemNode(app, 'Delete')
    .dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await app.settle(600);
  assertEqual(sent.length, 1, `the menu's Delete destroyed nothing (${sent.length} requests)`);
  assertEqual(sent[0].ids, [target], 'the menu destroyed something other than the photo');
});

console.log('video: the media filter is a real control, and the server owns it');

/**
 * Puts the media filter on Videos and waits for a page that answers it.
 *
 * Polled, like `openGroups`, because a cold start has to load status and start the
 * album index first and a fixed wait is either a flake or a needless delay on every
 * other run.
 *
 * @return the tiles of that page, which are all videos — the server filtered them,
 *         so this is also how these checks find a clip without assuming the
 *         library's default sort happens to put one on screen.
 */
async function showVideos(app) {
  app.click('#mediaChips [data-media="videos"]');
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await app.settle(250);
    const chips = app.$('mediaChips');
    if (chips && chips.querySelector('[data-media="videos"]').getAttribute('aria-pressed') === 'true'
        && app.window.document.querySelector('#grid .tile')) {
      return [...app.window.document.querySelectorAll('#grid .tile')];
    }
  }
  throw new Error('the grid never showed a videos-filtered page');
}

/**
 * Puts the media filter on Photos and waits for a page that answers it.
 *
 * @return the tiles of that page — all photographs, because the server filtered
 *         them.
 */
async function showPhotos(app) {
  app.click('#mediaChips [data-media="images"]');
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await app.settle(250);
    const chips = app.$('mediaChips');
    if (chips && chips.querySelector('[data-media="images"]').getAttribute('aria-pressed') === 'true'
        && app.window.document.querySelector('#grid .tile')) {
      return [...app.window.document.querySelectorAll('#grid .tile')];
    }
  }
  throw new Error('the grid never showed a photos-filtered page');
}

/**
 * Records every `play()` and `pause()` the client makes on `#lightboxVideo`.
 *
 * ## Why this exists, and why it is not `video.paused`
 *
 * jsdom has no media stack. `HTMLMediaElement.play`, `.pause` and `.load` are
 * reported as "not implemented" on the virtual console rather than throwing, so
 * every one of them here is a no-op that does nothing to any state. That gives two
 * ways for a playback assertion to pass for the wrong reason, and this suite is
 * built to avoid both:
 *
 * - **Asserting `video.paused === true`** proves nothing at all. It is true before
 *   the client does anything, it is true after `pause()` that did nothing, and it
 *   is true on a build that never calls `pause()` at all. The assertion would hold
 *   on the exact regression it is meant to catch.
 * - **Asserting a `<video>` exists** proves the element was built, which is a real
 *   invariant — and says nothing about whether it kept playing afterwards. A video
 *   element that never loads pixels is the other trap WEB-UI-TESTS.md names.
 *
 * So the invariant pinned is the one the *client* controls: it calls `pause()`
 * before it replaces or hides the clip. That is observable in jsdom because it is
 * the client's own method call, and it is the thing a regression would drop.
 *
 * @return the call log: `{play: n, pause: n, reset(): void}`.
 */
function watchMedia(app) {
  const video = app.$('lightboxVideo');
  const log = { play: 0, pause: 0 };
  video.play = () => { log.play += 1; };
  video.pause = () => { log.pause += 1; };
  log.reset = () => { log.play = 0; log.pause = 0; };
  return log;
}

/** Opens the lightbox on a tile with a double-click, the way the grid does. */
async function openLightboxOn(app, tile) {
  tile.dispatchEvent(new app.window.MouseEvent('dblclick', { bubbles: true, cancelable: true }));
  await app.settle(250);
  assertEqual(app.$('lightbox').hidden, false, 'the lightbox did not open');
}

await check('the media filter offers All / Photos / Videos, and sends what it says', async (app) => {
  // The regression this pins. There was a *disabled* checkbox reading "Images only"
  // whose tooltip claimed video support was planned — a control that could not be
  // operated and stated a falsehood about what the app does. Asserted on the
  // absence of the markup and then on the three real options, because a control
  // replaced by a differently-named one is still a regression.
  assert(app.$('mediaChips'), 'there is no media control at all');
  assert(!/Images only/.test(app.$('controlPanel').textContent),
    'the dead "Images only" checkbox is still on screen');
  assert(!/video support is planned/i.test(app.$('controlPanel').innerHTML),
    'the panel still says video support is planned');
  const chips = [...app.$('mediaChips').querySelectorAll('[data-media]')];
  assertEqual(chips.map((c) => c.dataset.media), ['all', 'images', 'videos'],
    'the media control is not All / Photos / Videos');

  // All is the default and the selected one, before anything has been asked for.
  assertEqual(chips[0].getAttribute('aria-pressed'), 'true', 'All is not the selected filter at boot');
  assertEqual(chips[0].classList.contains('active'), true, 'the selected chip is not marked active');
  assertEqual(chips[1].getAttribute('aria-pressed'), 'false', 'more than one chip claims to be selected');
});

await check('every grid request carries the media filter', async (app) => {
  // The query the client runs has to be the query the server sees, for the same
  // reason `album` is always sent: a keyset cursor minted under one media selection
  // describes a position inside a different result set, and the server refusing it
  // is the only thing stopping page two from splicing photos and clips together.
  const asked = [];
  const real = app.window.fetch;
  app.window.fetch = async (input, init) => {
    const path = new URL(typeof input === 'string' ? input : input.url, app.window.location.href).pathname;
    if (path.endsWith('/api/photos')) {
      const parsed = new URL(typeof input === 'string' ? input : input.url, app.window.location.href);
      asked.push(parsed.searchParams.get('media'));
    }
    return real(input, init);
  };
  await showVideos(app);
  assert(asked.length > 0, 'no page was requested');
  assert(asked.every((value) => value === 'videos'),
    `a page was fetched without the media filter in force: ${JSON.stringify(asked)}`);
  // And it is sent even when it is `all`: "absent" and "unfiltered" are different
  // queries, and a client that omitted the default would be relying on the server's
  // default staying put.
  app.click('#mediaChips [data-media="all"]');
  await app.settle(500);
  assert(asked[asked.length - 1] === 'all',
    `the default media filter is omitted rather than sent: ${JSON.stringify(asked)}`);
});

await check('the grid renders what the server applied, not what was asked for', async (app) => {
  // The echo is the point of `filter.media`: the chips must be able to disagree with
  // the click that produced the page. A client that painted from its own request
  // would show "Videos" over a grid of photographs, which is the one state in which
  // every number on screen is a lie.
  //
  // Asserted against the rows the server actually returned — every tile on the page
  // carries a video's marks — rather than against the click, so this holds however
  // the server answered.
  const tiles = await showVideos(app);
  assert(tiles.length > 0, 'the videos-filtered page is empty');
  for (const tile of tiles) {
    assert(/, Video/.test(tile.getAttribute('aria-label') || ''),
      `a tile on a videos-filtered page is not announced as a video: ${tile.getAttribute('aria-label')}`);
    assert(tile.querySelector('.tile-play'), 'a tile on a videos-filtered page has no play glyph');
  }
});

await check('the chips follow the server\'s echo, not the click that asked', async (app) => {
  // The echo is the whole reason `filter.media` is on the wire. Painted from the
  // click instead, a control could say "Videos" over a grid of photographs — the
  // one state in which every number on screen is a lie — and nothing would say so.
  //
  // The skew is injected here rather than waited for, because a real server
  // answering a real `?media=videos` echoes `videos` and the guarantee would hold
  // trivially: a client that ignored the echo entirely would pass this. Rewriting
  // the echoed value is what makes it a test of the client's behaviour rather than
  // of the server's agreeableness.
  const real = app.window.fetch;
  let rewrote = 0;
  app.window.fetch = async (input, init) => {
    const response = await real(input, init);
    const path = new URL(typeof input === 'string' ? input : input.url, app.window.location.href).pathname;
    if (!path.endsWith('/api/photos') || rewrote) return response;
    const payload = await response.json();
    if (!payload.filter || payload.filter.media !== 'videos') return response;
    rewrote += 1;
    // The server reports it applied something *other* than what was asked for.
    return { ...response, async json() { return { ...payload, filter: { ...payload.filter, media: 'all' } }; } };
  };

  app.click('#mediaChips [data-media="videos"]');
  // Polled, not slept: the assertion is about the *request* having been made and
  // answered, and a fixed interval that suffices on a warm machine is a flake on a
  // cold one. `settled` also would not do — the client renders the grid before the
  // rewritten echo arrives, so a tile on screen is not evidence the echo landed.
  for (let attempt = 0; attempt < 40 && rewrote === 0; attempt += 1) await app.settle(100);
  assert(rewrote > 0, 'the videos-filtered page carrying the echo was never fetched');
  assertEqual(app.$('mediaChips').querySelector('[data-media="all"]').getAttribute('aria-pressed'), 'true',
    'the chips still show the click rather than the media the server applied');
  assertEqual(app.$('mediaChips').querySelector('[data-media="videos"]').getAttribute('aria-pressed'), 'false',
    'the Videos chip is still marked as the filter in force');
});

await check('"Select all matching" pins the media dimension in the snapshot', async (app) => {
  // The load-bearing safety property, and it is on the wire, not in the client's
  // head. The snapshot is what `/api/selection/preview` resolves and what
  // `/api/delete` re-resolves, so a snapshot missing `media` resolves to every
  // photo *and video* in the library — on a grid the reader is looking at with
  // videos filtered out.
  await showVideos(app);
  const sent = [];
  const real = app.window.fetch;
  app.window.fetch = async (input, init) => {
    const path = new URL(typeof input === 'string' ? input : input.url, app.window.location.href).pathname;
    if (path.endsWith('/api/selection/preview')) sent.push(JSON.parse(init.body || '{}'));
    return real(input, init);
  };
  app.click('selectAllMatching');
  // Poll for the request rather than sleeping a fixed interval. How long the
  // videos-filtered grid took to render depends on how many clips are scored and
  // how long the server takes to answer, and a fixed sleep that is long enough on
  // a fast machine is a flake on a slow one — the request simply had not been made
  // yet, and the case failed for having been too early rather than for being wrong.
  for (let attempt = 0; attempt < 40 && sent.length === 0; attempt += 1) await app.settle(100);

  assertEqual(sent.length, 1, `the selection was not resolved (${sent.length} requests)`);
  assertEqual(sent[0].mode, 'matching', 'the snapshot is not a filter');
  assertEqual(sent[0].filter.media, 'videos',
    'the snapshot did not pin the media dimension, so it would resolve to the whole library');
  assert(sent[0].filter.album !== undefined, 'the album dimension stopped being pinned');
  assert(sent[0].filter.lo !== undefined && sent[0].filter.hi !== undefined,
    'the score bounds stopped being pinned');
});

await check('a snapshot taken under one media filter cannot be deleted under another', async (app) => {
  // The failure this exists to prevent: a selection snapshotted on a
  // videos-filtered grid, then the reader switches to Photos, and the Delete
  // button is still live over a set nobody agreed to.
  const sent = interceptDeletes(app);
  await showVideos(app);
  app.click('selectAllMatching');
  await app.settle(700);
  assertEqual(app.$('deleteButton').disabled, false, 'the button was dead with a resolvable selection');

  app.click('#mediaChips [data-media="images"]');
  await app.settle(700);
  assertEqual(app.$('deleteButton').disabled, true, 'the button was live over a stale selection');
  app.click('deleteButton');
  app.key('Backspace');
  await app.settle(600);
  assertEqual(sent.length, 0, 'a selection was destroyed under a different media filter');
});

console.log('video: a tile is never mistaken for a photograph');

await check('a clip\'s tile says what it is, where the tile no longer prints it', async (app) => {
  const tiles = await showVideos(app);
  const tile = tiles[0];
  const label = tile.getAttribute('aria-label') || '';
  const title = tile.getAttribute('title') || '';

  // The media type is named in both, and the length with it when there is one. This
  // is where this codebase puts what a tile does not draw — the date, the album and
  // the favourite protection are all here already — so a clip joins them rather than
  // getting a parallel mechanism.
  assert(/Video/.test(label), `the accessible name does not say it is a clip: ${label}`);
  assert(/Video/.test(title), `the tooltip does not say it is a clip: ${title}`);

  // The badge is in the corner opposite the score, and the score is still where it
  // was — the media marks are additions to a tile, not a re-layout of one.
  const badge = tile.querySelector('.tile-duration');
  const score = tile.querySelector('.tile-score');
  assert(badge, 'a video tile has no length badge');
  assert(score, 'a video tile has no score badge');
  assert(/^\d+:\d{2}(:\d{2})?$/.test(badge.textContent),
    `the length badge is not m:ss or h:mm:ss: ${badge.textContent}`);
  // Cross-checked against the tooltip rather than against a literal, because the
  // number on the badge is the server's value and this suite runs on somebody's real
  // library: if the tile names a length at all, the badge has to be that same one.
  const named = title.match(/Video, (\d+:\d{2}(?::\d{2})?)/);
  if (named) {
    assertEqual(badge.textContent, named[1],
      'the badge and the tooltip disagree about how long the clip is');
  }
  // The poster frame is the same thumbnail route a photograph uses — there is no
  // second image path, and the assertion is on the route rather than on pixels
  // because jsdom never loads an image.
  assert(/^\/api\/photo\/.+\/thumbnail\?size=\d+$/.test(tile.querySelector('img').getAttribute('src')),
    `a video tile does not use the existing thumbnail route: ${tile.querySelector('img').getAttribute('src')}`);
});

await check('a photograph still has neither mark', async (app) => {
  // The other direction. A play glyph or a length badge on a photograph is a grid
  // that cannot be trusted, and it is the failure mode that a "show video marks
  // everywhere" implementation would produce.
  const tiles = await showPhotos(app);
  assert(tiles.length > 0, 'the photos-filtered page is empty');
  for (const tile of tiles) {
    assertEqual(tile.querySelector('.tile-duration'), null, 'a photograph is showing a length badge');
    assertEqual(tile.querySelector('.tile-play'), null, 'a photograph is showing a play glyph');
    assert(!/Video/.test(tile.getAttribute('aria-label') || ''),
      `a photograph is announced as a clip: ${tile.getAttribute('aria-label')}`);
  }
});

console.log('video: the lightbox plays it');

await check('a clip renders as a <video> with the route, the poster and no autoplay', async (app) => {
  const tiles = await showVideos(app);
  await openLightboxOn(app, tiles[0]);
  const id = tiles[0].dataset.id;
  const encoded = app.window.encodeURIComponent(id);
  const video = app.$('lightboxVideo');

  assertEqual(video.hidden, false, 'a clip did not put a <video> on the stage');
  assertEqual(app.$('lightboxImage').hidden, true, 'the <img> is still on the stage as well');
  assertEqual(video.tagName, 'VIDEO', 'the clip is not rendered as a video element');
  assertEqual(video.getAttribute('src'), `/api/photo/${encoded}/video`,
    'the clip is not sourced from the video route');
  assertEqual(video.getAttribute('poster'), `/api/photo/${encoded}/preview?size=2048`,
    'the poster is not the existing preview route');
  assertEqual(video.hasAttribute('autoplay'), false, 'the clip autoplays');
  assertEqual(video.getAttribute('preload'), 'metadata', 'the clip preloads more than metadata');
  assertEqual(video.hasAttribute('playsinline'), true, 'playsinline is missing, so iOS would take over');
  assertEqual(video.controls, true, 'the clip has no transport');
  // The encoding is load-bearing, and it is asserted on the substring rather than
  // on a pattern: a `localIdentifier` contains `/`, so the identifier segment of the
  // src must be the escaped form and must not carry a raw separator. Skipped when
  // this library's identifiers happen not to contain one — asserting a pattern
  // about a fixture's shape would be asserting about the fixture.
  const raw = video.getAttribute('src');
  if (id.includes('/')) {
    assert(raw.includes(encoded), `the identifier was not percent-encoded into the src: ${raw}`);
    assert(!raw.slice('/api/photo/'.length, -'/video'.length).includes('/'),
      `a raw path separator reached the video route: ${raw}`);
  }
});

await check('a clip is never started by this client', async (app) => {
  // Asserted on the client's own `play()` calls, not on `video.paused` — see
  // `watchMedia` for why the latter would hold on a build that played nothing at
  // all, and for why an element that never loads pixels proves nothing either.
  const tiles = await showVideos(app);
  const media = watchMedia(app);
  await openLightboxOn(app, tiles[0]);
  assertEqual(media.play, 0, 'opening the lightbox started the clip');
  assertEqual(app.$('lightboxVideo').autoplay, false, 'the element autoplays');
});

await check('paging away from a clip pauses it and tears it down', async (app) => {
  // The bug the lightbox queue reindexing comments describe, with sound: a clip that
  // keeps playing underneath the next photo. The invariant pinned is the client's
  // own `pause()` call, which is the only part of it jsdom can observe.
  const tiles = await showVideos(app);
  await openLightboxOn(app, tiles[0]);
  const media = watchMedia(app);
  const first = app.$('lightboxVideo').getAttribute('src');

  app.click('lightboxNext');
  await app.settle(400);
  assert(media.pause > 0, 'paging did not pause the clip it was showing');
  const second = app.$('lightboxVideo').getAttribute('src');
  assert(second !== first, 'paging did not change what the stage is showing');
  // Torn down, not merely hidden: a retained `<video>` holds a decoder and its
  // stream open for the rest of the session.
  assert(/^https?:|^\/api\//.test(second || ''), 'the player was not re-sourced after the teardown');
});

await check('closing the lightbox pauses the clip and releases it', async (app) => {
  // A closed overlay with a paused-but-attached clip still holds that clip's decoder
  // and its half-open export request, and the next open races a resource the
  // previous one still owns.
  const tiles = await showVideos(app);
  await openLightboxOn(app, tiles[0]);
  const media = watchMedia(app);

  app.click('lightboxClose');
  await app.settle(500);
  assert(media.pause > 0, 'closing did not pause the clip');
  assertEqual(app.$('lightbox').hidden, true, 'the lightbox stayed open');
  assertEqual(app.$('lightboxVideo').getAttribute('src'), null,
    'the player still has a source after the lightbox closed');
  assertEqual(app.$('lightboxVideo').getAttribute('poster'), null,
    'the player still holds a poster after the lightbox closed');
});

await check('a clip in the lightbox keeps the grid\'s context menu', async (app) => {
  // The menu is anchored to the element the photo is drawn in, and that element is a
  // `<video>` for a clip. Asserted on the menu *opening* and on an item being
  // present, because the anchor is the thing that changed: a listener scoped to the
  // `<img>` alone leaves a clip as the one photo in the app with no menu, and that
  // is silent — the reader simply right-clicks and gets nothing.
  const tiles = await showVideos(app);
  await openLightboxOn(app, tiles[0]);
  const video = app.$('lightboxVideo');
  video.dispatchEvent(new app.window.MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
  await app.settle(250);
  assertEqual(app.$('tileMenuLayer').hidden, false, 'right-clicking a clip did not open the menu');
  const labels = [...app.$('tileMenu').children]
    .filter((n) => n.getAttribute('role') === 'menuitem')
    .map((n) => (n.firstChild ? n.firstChild.textContent : ''));
  assert(labels.includes('Delete'), `the clip's menu is not the photo menu: ${labels.join(' | ')}`);
  assert(!labels.some((l) => l === ''), 'the clip\'s menu has an unlabelled item');
});

await check('only the arrows navigate: a click on the photograph does not', async (app) => {
  // There used to be a click-to-advance on the photograph itself, and it stopped
  // being honest the moment the still became a stage-sized `object-fit: contain`
  // box: the element that received the click covered the whole stage, including the
  // letterbox beside a portrait photograph, so most of the hit area was not the
  // photograph it claimed to be. What navigates now is what looks like navigation.
  const [tile] = stillTiles(app);
  assert(tile, 'the first page has no photograph on it');
  await openLightboxOn(app, tile);
  const position = app.$('lightboxPosition').textContent;

  app.$('lightboxImage').dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, false, 'clicking a photograph closed the lightbox');
  assertEqual(app.$('lightboxPosition').textContent, position,
    'clicking a photograph paged to the next one');
  // …including the letterbox: the stage's own box is not the photograph either.
  app.$('lightboxStage').dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightboxPosition').textContent, position,
    'clicking the stage beside the photograph paged to the next one');

  // And the arrow still does, which is the half that a "never navigate" version
  // would break.
  app.click('lightboxNext');
  await app.settle(300);
  assert(app.$('lightboxPosition').textContent !== position,
    'the › button did not page to the next photograph');
});

await check('a clip keeps every click on its own transport', async (app) => {
  // A `<video controls>` owns its own clicks: play/pause, the scrub bar, the volume.
  // Anything on the stage that paged on a click in that region would take the clip
  // away mid-seek, arriving at "it kept playing under the next photo" from the other
  // end.
  const tiles = await showVideos(app);
  await openLightboxOn(app, tiles[0]);
  const before = app.$('lightboxVideo').getAttribute('src');
  const position = app.$('lightboxPosition').textContent;

  app.$('lightboxVideo').dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, false, 'clicking the clip closed the lightbox');
  assertEqual(app.$('lightboxVideo').getAttribute('src'), before, 'clicking the clip paged to another photo');
  assertEqual(app.$('lightboxPosition').textContent, position, 'clicking the clip paged to another photo');
});

await check('Space still toggles the preview on a clip tile, and Enter still opens it', async (app) => {
  // `buildTile`'s keydown contract is unchanged by video support, and this is the
  // test that says so. Space previews (it does not select) and the same key again
  // puts it away; Enter opens.
  const tiles = await showVideos(app);
  const tile = tiles[0];

  tile.dispatchEvent(new app.window.KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, false, 'Space did not open the preview on a clip tile');
  assert(/Nothing selected/.test(app.$('selectionSummary').textContent),
    `Space selected the clip instead of previewing it: ${app.$('selectionSummary').textContent}`);

  app.key(' ');
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, true, 'Space did not close the preview on a clip');

  tile.dispatchEvent(new app.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
  await app.settle(300);
  assertEqual(app.$('lightbox').hidden, false, 'Enter did not open the preview on a clip tile');
});

await check('a photograph in the lightbox is still an <img>', async (app) => {
  // The other direction again, and the one a "video support" change breaks by
  // accident: swapping the element for a `<video>` unconditionally leaves every
  // photograph rendered by the media element, which cannot show a picture at all.
  const [tile] = await showPhotos(app);
  assert(tile, 'the photos-filtered grid is empty');
  await openLightboxOn(app, tile);

  assertEqual(app.$('lightboxImage').hidden, false, 'a photograph is not shown by the <img>');
  assertEqual(app.$('lightboxVideo').hidden, true, 'a photograph put a <video> on the stage');
  // A still route, and not the clip's: which *rendition* of it is on the stage at
  // any moment is the still walk's business and is checked on its own below.
  const src = app.$('lightboxImage').getAttribute('src');
  assert(/^\/api\/photo\/.+\/(thumbnail\?size=\d+|preview\?size=\d+)$/.test(src),
    `a photograph is not sourced from a still route: ${src}`);
  assertEqual(app.$('lightboxDurationRow').hidden, true,
    'a photograph is showing a length');
});

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) process.exit(1);

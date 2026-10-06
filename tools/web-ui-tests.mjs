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

/**
 * Asserts that `expected` appears in `actual`, in the same relative order.
 *
 * A plain equality check would be hostage to pagination: the client loads the next
 * page whenever the sentinel comes into view, so the grid legitimately *grows*
 * between two reads of it. What these tests are about is that a particular photo
 * left, and that everything else stayed put — not that no new page arrived.
 */
function assertSubsequence(actual, expected, message) {
  let at = 0;
  for (const id of actual) {
    if (id === expected[at]) at += 1;
  }
  if (at !== expected.length) {
    const missing = expected.filter((id) => !actual.includes(id));
    throw new Error(`${message}\n            ${missing.length} missing: ${missing.slice(0, 3).join(', ')}`
      + `\n            order ${at}/${expected.length} of the expected ids were in place`);
  }
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
  assertEqual(button.textContent, 'Delete 2 photos',
    'the button does not carry the count the server resolved');
});

await check('the count is the resolved one, and it is singular for one photo', async (app) => {
  clickTile(app, app.tileIds()[0]);
  await app.settle(500);
  assert(/^Delete 1 photo$/.test(app.$('deleteButton').textContent),
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
  const id = tile.dataset.id;
  const target = tile;

  target.dispatchEvent(new app.window.KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
  await app.settle(200);
  assertEqual(app.$('lightbox').hidden, false, 'Space did not open the preview');
  assertEqual(app.$('lightboxScore').textContent !== '—', true, 'the preview did not load a photo');

  app.key(' ');
  await app.settle(200);
  assertEqual(app.$('lightbox').hidden, true, 'Space did not close the preview');
  void id;
});

await check('Space no longer toggles the selection', async (app) => {
  const target = app.window.document.querySelector('#grid .tile');
  const id = target.dataset.id;
  target.dispatchEvent(new app.window.KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
  await app.settle(150);
  const summary = app.$('selectionSummary').textContent;
  assert(/Nothing selected/.test(summary), `Space selected the photo instead of previewing it: ${summary}`);
  void id;
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
  const id = cell.dataset.id;
  cell.dispatchEvent(new app.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await app.settle(200);
  assertEqual(app.$('lightbox').hidden, true, 'a single click opened the preview');
  assert(cell.classList.contains('selected'), 'the clicked cell is not marked as selected');
  assertEqual(cell.getAttribute('aria-pressed'), 'true', 'the cell was not announced as selected');
  assert(/1 photo selected/.test(app.$('selectionSummary').textContent),
    `the selection bar did not count it: ${app.$('selectionSummary').textContent}`);
  void id;
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

  const summary = app.$('selectionSummary').textContent;
  assert(/4 photos selected/.test(summary), `the range selected the wrong span: ${summary}`);
  for (const index of [1, 2, 3, 4]) {
    assert(cellAt(app, card, index).classList.contains('selected'),
      `rank ${index + 1} is in the range but is not marked`);
  }
  assert(!cellAt(app, card, 5).classList.contains('selected'), 'the range ran past its end');
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
  assertEqual(del.hint, '1 photo', 'the hint does not say what will be covered');
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

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) process.exit(1);

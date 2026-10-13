// Exercise the real client with deterministic pages, without a Photos library.
import assert from 'node:assert/strict';
import { openApp } from './web-ui-harness.mjs';

const requests = [];
// The favourites this library has, held for real rather than per-response: a favourite
// set in one request has to still be set in the next, or "mark this photo a favourite"
// could not change what a later page returns — which is the whole of the case below it.
const favorites = new Set(['third']);
const row = (id) => ({ id, score: 0.5, date: 1, width: 100, height: 100, favorite: favorites.has(id) });
const app = await openApp({
  fetch: async (input, init) => {
    const url = new URL(input);
    let payload;
    switch (url.pathname) {
      case '/api/status':
        payload = {
          authorization: 'authorized', score: { min: 0, max: 1 },
          library: { total: 3, favorites: favorites.size, videos: 0 },
          analysis: { phase: 'up_to_date', analyzed: 3 },
        };
        break;
      case '/api/albums':
        payload = { albums: [], indexComplete: true };
        break;
      case '/api/favorites': {
        const body = JSON.parse((init && init.body) || '{}');
        const ids = Array.isArray(body.ids) ? body.ids : [];
        ids.forEach((id) => (body.favorite ? favorites.add(id) : favorites.delete(id)));
        payload = { requested: ids.length, resolved: ids.length, confirmed: ids.length,
                    missing: 0, protectedFavorites: 0, errors: [] };
        break;
      }
      case '/api/photos': {
        requests.push(url);
        const media = url.searchParams.get('media');
        const favorites = url.searchParams.get('favorites');
        const cursor = url.searchParams.get('cursor');
        // One library of three photographs, the last of them a favourite — so the
        // favourites filter has something real to drop, and dropping it is visible
        // as a row rather than as an empty page.
        const photos = media === 'videos' ? []
          : media === 'all' ? [row('image')]
          : [row('first'), row('second'), row('third')];
        const kept = photos.filter((photo) => favorites !== 'exclude' || !photo.favorite);
        payload = {
          total: kept.length,
          items: cursor ? kept.slice(2) : kept.slice(0, 2),
          nextCursor: media === 'images' && !cursor && kept.length > 2 ? 'second-page' : null,
          bounds: { min: 0, max: 1 },
          filter: { media, favorites },
        };
        break;
      }
      default:
        throw new Error(`Unexpected request: ${url.pathname}`);
    }
    return new Response(JSON.stringify(payload), {
      headers: { 'Content-Type': 'application/json' },
    });
  },
});

async function until(predicate) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await app.settle(20);
  }
  assert.fail(`Client did not reach the expected page state: ${JSON.stringify({
    tiles: app.tileIds(), requests: requests.map(String), errors: app.errors.map((e) => e.message),
  })}`);
}

try {
  await until(() => app.tileIds().length === 3);
  assert.equal(app.$('matchCount').textContent, '3');
  assert.deepEqual(app.tileIds(), ['first', 'second', 'third']);
  assert.equal(requests.length, 2);
  assert.equal(requests[1].searchParams.get('cursor'), 'second-page');
  assert.equal(app.$('loadMore').hidden, true, 'the final page clears the cursor');
  console.log('PASS matching count, next-page cursor, and end of pagination');

  app.click('#mediaChips [data-media="all"]');
  await until(() => app.tileIds().length === 1 && app.tileIds()[0] === 'image');
  assert.equal(app.$('matchCount').textContent, '1', 'a new filter updates the count');
  assert.equal(app.$('loadMore').hidden, true);
  console.log('PASS filter reload replaces the count and pagination state');

  app.click('#mediaChips [data-media="videos"]');
  await until(() => app.$('matchCount').textContent === '0');
  assert.equal(app.tileIds().length, 0);
  assert.equal(app.$('loadMore').hidden, true);
  assert.equal(app.$('emptyState').hidden, false);
  console.log('PASS an empty filtered page clears the previous count');

  // The favorites filter, on the grid it belongs to. A "Favorite" label names the
  // dimension and one tag answers it in two states — "don’t care" while everything is
  // on screen, "no" while the marked ones are hidden. The server's third state
  // (`only`) has no answer here at all: a cleaner is not a favorites browser.
  app.click('#mediaChips [data-media="images"]');
  await until(() => app.tileIds().length === 3);
  const tag = app.$('favoriteToggle');
  assert.equal(app.$('favoritesGroup').querySelector('.control-label').textContent, 'Favorite',
    'the control no longer names the dimension it acts on');
  assert.equal(tag.textContent, 'don’t care', 'the tag does not start answering for its state');
  assert.equal(tag.getAttribute('aria-pressed'), 'false');
  assert.equal(app.window.document.querySelectorAll('#favoriteToggle').length, 1,
    'there is more than one favorites control on the panel');
  assert.equal(tag.querySelectorAll('*').length, 0, 'the tag grew a label or a glyph inside it');
  console.log('PASS one tag under a Favorite label, answering “don’t care”');

  app.click('#favoriteToggle');
  // Both halves, and the second one is the point: this reload awaits the answer
  // before it touches the grid, so "the request went out" and "the grid changed"
  // are two different moments and waiting for only the first is a race.
  // Keyed on the count read-out rather than on the tile count: the read-out is written
  // by `absorbPage`, after the rows, so it cannot report the new answer for a grid that
  // has not been swapped yet.
  await until(() => requests[requests.length - 1].searchParams.get('favorites') === 'exclude'
    && app.$('matchCount').textContent === '2');
  assert.deepEqual(app.tileIds(), ['first', 'second'], 'the favorites filter did not reach the page');
  assert.equal(app.$('matchCount').textContent, '2', 'the count did not follow the filter');
  assert.equal(tag.textContent, 'no', 'the tag did not repaint itself for the new state');
  assert.equal(tag.getAttribute('aria-pressed'), 'true');
  // The hidden count is in the tooltip and the accessible name, and nowhere else: the
  // header reports the library's assets and its clips, not what this filter withholds.
  assert.match(tag.title, /^Favorite: no — the 1 favorite PhotoCleaner has scored/);
  assert.match(tag.getAttribute('aria-label'), /^Favorite: no/,
    'the accessible name no longer leads with the label beside the tag');
  console.log('PASS one press hides the favorites: tag, aria-pressed, grid and count');

  app.click('#favoriteToggle');
  // Back to `include`. The window restarts at page one and the rest of the grid comes
  // from the sentinel as the reader scrolls — which is the contract of every first
  // page, and the reason this path exists at all: a reload that refilled itself to the
  // depth it had reached *is* the full refresh. So two tiles are loaded and the count
  // above the slider still reports the server's three, exactly as it does for any
  // first page.
  await until(() => requests[requests.length - 1].searchParams.get('favorites') === 'include'
    && app.$('matchCount').textContent === '3');
  assert.equal(tag.textContent, 'don’t care', 'the tag did not come back to its other answer');
  assert.equal(tag.getAttribute('aria-pressed'), 'false');
  assert.equal(app.$('matchCount').textContent, '3',
    'the count should report the server’s total rather than the loaded page');
  assert.equal(app.$('loadMore').hidden, false, 'the reader is not told the list ended when it did not');
  console.log('PASS a second press brings the favorites back, as one page and the server’s count');

  // The preview survives the switch. A reader reaches for this tag in the middle of a
  // review, so pressing it with a photograph on the stage must not close the stage,
  // empty the contact sheet, or start the grid again from nothing.
  //
  // Page two is pulled through Load more rather than waiting for the sentinel: the
  // harness stubs IntersectionObserver to a no-op, so a scroll-triggered page would
  // never arrive here, and this case is about the preview, not about paging.
  await until(() => app.$('loadMore').hidden === false);
  app.click('#loadMoreButton');
  await until(() => app.tileIds().length === 3);
  const onStage = app.tileIds()[1];              // a photograph the filter keeps
  const tile = app.window.document.querySelector(`#grid .tile[data-id="${onStage}"]`);
  tile.dispatchEvent(new app.window.KeyboardEvent('keydown',
    { key: ' ', bubbles: true, cancelable: true }));
  await until(() => app.$('lightbox').hidden === false);
  const stage = app.$('lightboxImage').getAttribute('src');
  assert.ok(stage, 'the preview did not put a photograph on the stage');

  app.click('#favoriteToggle');
  await until(() => app.$('matchCount').textContent === '2');
  assert.equal(app.$('lightbox').hidden, false, 'the preview closed on a favorites switch');
  assert.equal(app.$('lightboxImage').getAttribute('src'), stage,
    'the preview re-fetched the photograph it was already showing');
  assert.match(app.$('lightboxPosition').textContent, /2 of 2 loaded · 2 matching/,
    `the preview is pointing at the wrong photograph: ${app.$('lightboxPosition').textContent}`);
  // Only one page is loaded after a switch, and the read-out says so rather than
  // claiming the reader is looking at the whole result set.
  assert.equal(app.tileIds().length, 2, 'the switch refilled the grid instead of paging from one');
  console.log('PASS the preview survives a favorites switch, on the same photograph');

  // And the photograph that leaves the set takes the preview with it to its
  // replacement, rather than closing: favouriting the one on the stage is exactly the
  // press this filter exists for.
  app.click('#lightboxFavoriteToggle');
  await until(() => app.$('matchCount').textContent === '1');
  assert.equal(app.$('lightbox').hidden, false,
    'favouriting the photograph on the stage closed the preview');
  assert.equal(app.$('lightboxImage').getAttribute('src'), '/api/photo/first/thumbnail?size=512',
    'the preview kept showing a photograph the filter now hides');
  assert.match(app.$('lightboxPosition').textContent, /1 of 1 loaded · 1 matching/,
    `the preview is not on the photograph that replaced the one that left: ${app.$('lightboxPosition').textContent}`);
  console.log('PASS favouriting the photograph on the stage moves the preview, it does not close it');
} finally {
  app.close();
}

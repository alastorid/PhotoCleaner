// Exercise the real client with deterministic pages, without a Photos library.
import assert from 'node:assert/strict';
import { openApp } from './web-ui-harness.mjs';

const requests = [];
const row = (id, favorite = false) => ({ id, score: 0.5, date: 1, width: 100, height: 100, favorite });
const app = await openApp({
  fetch: async (input) => {
    const url = new URL(input);
    let payload;
    switch (url.pathname) {
      case '/api/status':
        payload = {
          authorization: 'authorized', score: { min: 0, max: 1 },
          library: { total: 3, favorites: 1, videos: 0 },
          analysis: { phase: 'up_to_date', analyzed: 3 },
        };
        break;
      case '/api/albums':
        payload = { albums: [], indexComplete: true };
        break;
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
          : [row('first'), row('second'), row('third', true)];
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
  await until(() => requests[requests.length - 1].searchParams.get('favorites') === 'exclude');
  assert.equal(requests[requests.length - 1].searchParams.get('favorites'), 'exclude',
    'the filter was not sent on the wire, so the grid is the whole library');
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
  await until(() => app.tileIds().length === 3);
  assert.equal(tag.textContent, 'don’t care', 'the tag did not come back to its other answer');
  assert.equal(tag.getAttribute('aria-pressed'), 'false');
  assert.equal(requests[requests.length - 1].searchParams.get('favorites'), 'include',
    'the default is omitted rather than sent, and a cursor minted under "exclude" '
    + 'would then be replayed against a different result set');
  console.log('PASS a second press brings the favorites back, sent as a value not an absence');
} finally {
  app.close();
}

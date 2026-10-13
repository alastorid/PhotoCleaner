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

/** The favourites chip for one of the server's two offered values. */
const favoriteChip = (app, value) =>
  app.window.document.querySelector(`#favoriteChips [data-favorites="${value}"]`);

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

  // The favourites filter, on the grid the two buckets belong to. Two chips only:
  // "include" and "exclude" — the server's third bucket is not offered, because a
  // cleaner is not a favourites browser.
  app.click('#mediaChips [data-media="images"]');
  await until(() => app.tileIds().length === 3);
  assert.deepEqual(
    [...app.$('favoriteChips').querySelectorAll('[data-favorites]')].map((chip) => chip.dataset.favorites),
    ['include', 'exclude'],
    'the favourites filter offers a bucket the cleanup does not need',
  );
  assert.equal(favoriteChip(app, 'include').getAttribute('aria-pressed'), 'true');
  console.log('PASS the favourites filter starts unfiltered, with two buckets');

  app.click('#favoriteChips [data-favorites="exclude"]');
  await until(() => requests[requests.length - 1].searchParams.get('favorites') === 'exclude');
  assert.equal(requests[requests.length - 1].searchParams.get('favorites'), 'exclude',
    'the filter was not sent on the wire, so the grid is the whole library');
  assert.deepEqual(app.tileIds(), ['first', 'second'], 'the favourites filter did not reach the page');
  assert.equal(app.$('matchCount').textContent, '2', 'the count did not follow the filter');
  assert.equal(favoriteChip(app, 'exclude').getAttribute('aria-pressed'), 'true');
  assert.equal(favoriteChip(app, 'include').getAttribute('aria-pressed'), 'false');
  // The tooltip is the only place the hidden count appears, and it is the server's
  // count rather than a tally of what this client happens to have loaded.
  assert.match(favoriteChip(app, 'exclude').title, /1 favourite/);
  console.log('PASS hiding the favourites filters the grid, the count and the pressed state');

  app.click('#favoriteChips [data-favorites="include"]');
  await until(() => app.tileIds().length === 3);
  assert.equal(requests[requests.length - 1].searchParams.get('favorites'), 'include',
    'the default is omitted rather than sent, and a cursor minted under "exclude" '
    + 'would then be replayed against a different result set');
  console.log('PASS “All” brings the favourites back, and is sent as a value rather than an absence');
} finally {
  app.close();
}

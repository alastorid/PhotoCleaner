// Exercise the real client with deterministic pages, without a Photos library.
import assert from 'node:assert/strict';
import { openApp } from './web-ui-harness.mjs';

const requests = [];
const row = (id) => ({ id, score: 0.5, date: 1, width: 100, height: 100, favorite: false });
const app = await openApp({
  fetch: async (input) => {
    const url = new URL(input);
    let payload;
    switch (url.pathname) {
      case '/api/status':
        payload = {
          authorization: 'authorized', score: { min: 0, max: 1 },
          library: { total: 3, favorites: 0, videos: 0 },
          analysis: { phase: 'up_to_date', analyzed: 3 },
        };
        break;
      case '/api/albums':
        payload = { albums: [], indexComplete: true };
        break;
      case '/api/photos': {
        requests.push(url);
        const media = url.searchParams.get('media');
        const cursor = url.searchParams.get('cursor');
        payload = {
          total: media === 'videos' ? 0 : media === 'all' ? 1 : 3,
          items: media === 'videos' ? [] : media === 'all' ? [row('image')]
            : cursor ? [row('third')] : [row('first'), row('second')],
          nextCursor: media === 'images' && !cursor ? 'second-page' : null,
          bounds: { min: 0, max: 1 }, filter: { media },
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
} finally {
  app.close();
}
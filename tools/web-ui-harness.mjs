/**
 * A headless harness for the web client.
 *
 * Loads the *real* `web/index.html` and `web/app.js` into jsdom and points the
 * client at a running PhotoCleaner, so the DOM the tests poke at is the DOM the
 * app builds for itself. Nothing here re-implements app logic: the harness only
 * provides the browser the app expects and a way to read the result.
 *
 * Not part of the app or the shipped bundle — a developer tool for the behaviours
 * that `smoke-test.sh` can only grep for.
 *
 *   node tools/web-ui-harness.mjs http://127.0.0.1:8791
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
// jsdom is a developer dependency of this harness, declared in package.json and
// fetched by `npm install` — never vendored, and the harness ships in nothing.
// `JSDOM_PATH` still overrides the resolution, so a checkout with no install can
// point at an entry point resolved anywhere else.
const { JSDOM, VirtualConsole } = await import(
  process.env.JSDOM_PATH || 'jsdom'
);

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..', 'web');
let base = process.argv[2] || 'http://127.0.0.1:8791';

/** The harness surface the tests use. */
export async function openApp(options = {}) {
  base = options.base || base;
  const html = readFileSync(join(web, 'index.html'), 'utf8');
  // Per window, not per module: a harness that collects into one shared list makes
  // every later `openApp` fail its "booted cleanly" check on an error a previous
  // window already logged, which is a failure in the test rather than in the client.
  const errors = [];
  const virtualConsole = new VirtualConsole();
  virtualConsole.on('jsdomError', (error) => errors.push(error));
  virtualConsole.on('error', (...args) => errors.push(new Error(args.join(' '))));

  const dom = new JSDOM(html, {
    url: `${base}/`,
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    virtualConsole,
  });
  const { window } = dom;

  // The app talks to its own origin with relative URLs; jsdom does not fetch, and
  // `fetch` exists but would be cross-origin from `about:blank`. Point it at the
  // live server and let it behave normally.
  window.fetch = async (input, init) => {
    let url = typeof input === 'string' ? new URL(input, base).href : input;
    // The client asks for a whole page of the library, which on a real library is
    // thousands of tiles. These tests only ever touch the first handful, so the
    // page size is capped here. Rewriting the request rather than stubbing the
    // response keeps the client's own paging and index arithmetic on the real
    // path — a fake response would hide exactly the bugs worth catching.
    if (options.pageLimit) {
      const parsed = new URL(url, base);
      if (parsed.searchParams.has('limit')) {
        const asked = Number(parsed.searchParams.get('limit')) || options.pageLimit;
        parsed.searchParams.set('limit', String(Math.min(asked, options.pageLimit)));
        url = parsed.href;
      }
    }
    const response = await fetch(url, init);
    return {
      ok: response.ok,
      status: response.status,
      async json() { return response.json(); },
      async text() { return response.text(); },
    };
  };
  // jsdom has no layout, so anything that measures the viewport or an element's
  // box gets a plausible number instead of NaN. Only the observers and
  // scroll-into-view paths read these.
  window.scrollTo = () => {};
  // jsdom has no EventSource, and the client's live-refresh stream is not what
  // these tests are about. A stub that connects and stays quiet is enough, and it
  // is stubbed *before* the app boots so boot() cannot throw.
  window.EventSource = class {
    constructor() { this.readyState = 1; }
    addEventListener() {}
    removeEventListener() {}
    close() { this.readyState = 2; }
  };
  if (!window.IntersectionObserver) {
    window.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} };
  }
  window.Element.prototype.scrollIntoView = () => {};

  const source = readFileSync(join(web, 'app.js'), 'utf8');
  window.addEventListener('error', (event) => errors.push(event.error || new Error(event.message)));
  window.addEventListener('unhandledrejection', (event) => errors.push(event.reason));
  try {
    window.eval(source);
  } catch (error) {
    throw new Error(`app.js threw while booting: ${error.stack}`);
  }
  if (errors.length) {
    const first = errors[0];
    throw new Error(`app.js failed to boot cleanly: ${first.stack || first.message || first}`);
  }

  // The client boots on DOMContentLoaded, which jsdom fires for `dangerously`
  // before this resolves. Wait for the first render to land instead of guessing.
  await settled(window, options.timeout || 20000, errors);

  return new Harness(window, errors);
}

/**
 * Resolves once the first grid render has landed.
 *
 * The client has no "idle" signal to wait on — it is event-driven and stays idle
 * forever — so the only honest readiness condition is the thing under test: a tile
 * on screen. A timeout here means the client failed to boot, and the errors it
 * collected say why.
 */
async function settled(window, timeout, errors) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (window.document.querySelector('#grid .tile')) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const first = errors[0];
  throw new Error(`the client never rendered a tile${first ? `: ${first.message || first}` : ''}`);
}

class Harness {
  constructor(window, errors) {
    this.window = window;
    this.errors = errors;
    this.$ = (id) => window.document.getElementById(id);
  }

  /** Every tile id currently in the score grid, in DOM order. */
  tileIds() {
    return [...this.window.document.querySelectorAll('#grid .tile')]
      .map((tile) => tile.dataset.id);
  }

  /** Presses a key on `target` (default: the document). */
  key(name, init = {}) {
    const event = new this.window.KeyboardEvent('keydown', {
      key: name, bubbles: true, cancelable: true, ...init,
    });
    (init.target ? this.$(init.target) : this.window.document).dispatchEvent(event);
    return event;
  }

  click(selector, init = {}) {
    const node = this.$(selector) || this.window.document.querySelector(selector);
    if (!node) throw new Error(`no node for ${selector}`);
    node.dispatchEvent(new this.window.MouseEvent('click', {
      bubbles: true, cancelable: true, ...init,
    }));
    return node;
  }

  /** Lets queued promises and timers run. */
  async settle(ms = 250) {
    await new Promise((resolve) => setTimeout(resolve, ms));
  }

  close() { this.window.close(); }
}


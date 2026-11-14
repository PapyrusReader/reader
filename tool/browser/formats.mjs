import assert from 'node:assert/strict';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';

export async function checkFormats(browser, origin, reader) {
  const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const cases = [
    ['epub', 'gutenberg/alice.epub'],
    ['mobi', 'gutenberg/alice.mobi'],
    ['azw3', 'gutenberg/alice.azw3'],
    ['cbz', 'comics/pages.cbz'],
    ['cbr', 'comics/pages-rar4.cbr'],
    ['cbr', 'comics/pages-rar4-compressed.cbr'],
    ['cbr', 'comics/pages-rar5.cbr'],
    ['txt', null],
    ['pdf', '../../example/assets/a_tiny_pdf.pdf'],
  ];

  try {
    await page.goto(origin);
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await page.getByRole('button', { name: 'Open a book', exact: true }).waitFor();
    for (const [format, fixture] of cases) {
      const bytes = fixture ? await readFile(resolve(reader, 'test/fixtures', fixture))
        : Buffer.from('A plain text book\n\n' + 'A readable paragraph with Ελληνικά 日本語 🐇.\n\n'.repeat(3000));
      if (format !== 'pdf') {
        const result = await page.evaluate(async ({ format, encoded }) => {
          const script = await (await fetch('/assets/packages/papyrus_reader/assets/epub_worker')).text();
          const url = URL.createObjectURL(new Blob([script], { type: 'text/javascript' }));
          const worker = new Worker(url);
          URL.revokeObjectURL(url);
          const pending = new Map();
          let id = 0;
          worker.onmessage = event => {
            const message = typeof event.data === 'string' ? JSON.parse(event.data) : event.data;
            const task = pending.get(message.id);
            pending.delete(message.id);
            clearTimeout(task.timeout);
            if (message.error) task.reject(new Error(JSON.stringify(message)));
            else task.resolve(message.result);
          };
          const request = (command, argument) => new Promise((resolve, reject) => {
            const key = ++id;
            const timeout = setTimeout(() => reject(new Error(`Worker timed out: ${command}`)), 30000);
            pending.set(key, { resolve, reject, timeout });
            if (argument instanceof Uint8Array) worker.postMessage({ id: key, command, bytes: argument }, [argument.buffer]);
            else worker.postMessage({ id: key, command, argument });
          });
          let frames = 0, maxGap = 0, last, frameId;
          const tick = time => { if (last !== undefined) maxGap = Math.max(maxGap, time - last); last = time; frames++; frameId = requestAnimationFrame(tick); };
          frameId = requestAnimationFrame(tick);
          try {
            const bytes = Uint8Array.from(atob(encoded), char => char.charCodeAt(0));
            const fixed = format === 'cbz' || format === 'cbr';
            const metadata = await request(fixed ? `prepare_${format}` : format === 'epub' ? 'open' : `open_${format}`, bytes);
            if (fixed) {
              if (!(metadata.bytes instanceof Uint8Array) || String.fromCharCode(...metadata.bytes.subarray(0, 4)) !== '%PDF') {
                throw new Error('Invalid binary page document transport');
              }
              return { frames, maxGap, bytes: metadata.bytes.length };
            }
            let length = 0, images = 0;
            for (let chapter = 0; chapter < metadata.count; chapter++) {
              const content = await request('chapter', chapter);
              length += content.length;
              images += content.blocks.filter(block => block.kind === 'image').length;
            }
            return { frames, maxGap, length, images };
          } finally {
            cancelAnimationFrame(frameId);
            for (const task of pending.values()) clearTimeout(task.timeout);
            worker.terminate();
          }
        }, { format, encoded: bytes.toString('base64') });
        assert.ok(result.frames > 0, `${format} must leave browser rendering active`);
        if (result.length !== undefined) assert.ok(result.length > 100000, `${format} lost book text`);
        if (format === 'azw3') assert.ok(result.images > 0, 'KF8 cover must render');
        console.log(`PASS: ${fixture ?? format} browser worker ${JSON.stringify(result)}`);
      }

      // Exercise the public engine registration, binary transport, viewport and
      // navigation together through the example's real file picker.
      await page.goto(origin);
      await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
      const chooser = page.waitForEvent('filechooser');
      await page.getByRole('button', { name: 'Open a book', exact: true }).click();
      await (await chooser).setFiles({ name: `book.${format}`, mimeType: 'application/octet-stream', buffer: bytes });
      // The reader route and its first viewport become ready in separate
      // frames. A toggle sent while opening is intentionally ignored. Retry
      // only while controls remain absent, then test real page navigation.
      await page.getByRole('button', { name: 'Open a book', exact: true }).waitFor({ state: 'hidden', timeout: 30000 });
      const next = page.getByRole('button', { name: 'Next', exact: true });
      const deadline = Date.now() + 60000;
      while (!await next.isVisible() && Date.now() < deadline) {
        await page.getByRole('progressbar').waitFor({ state: 'hidden', timeout: 60000 });
        await page.mouse.click(550, 400);
        try { await next.waitFor({ timeout: 1500 }); }
        catch (error) { if (error.name !== 'TimeoutError') throw error; }
      }
      assert.ok(await next.isVisible(), `${format} reader did not become ready: ${await page.locator('body').innerText()}`);
      assert.ok(await next.isEnabled(), `${format} must have a readable next page`);
      const previous = page.getByRole('button', { name: 'Previous', exact: true });
      const mouseSwipe = async direction => {
        await page.mouse.click(20, 400);
        await next.waitFor({ state: 'hidden' });
        await page.waitForTimeout(300);
        // Start in the outer window margins, beyond the centered text column.
        await page.mouse.move(direction > 0 ? 1040 : 60, 400);
        await page.mouse.down();
        await page.mouse.move(direction > 0 ? 60 : 1040, 400, { steps: 18 });
        await page.mouse.up();
        await page.waitForTimeout(700);
        await page.mouse.click(20, 400);
        await previous.waitFor();
      };
      const location = async () => {
        const counter = page.getByRole('button', { name: /^Page \d+ of \d+\. Go to page$/ });
        if (await counter.count()) {
          const label = await counter.evaluate(element => element.getAttribute('aria-label') || element.textContent);
          return `:${label.match(/Page (\d+) of/)[1]}`;
        }
        return page.getByRole('group').evaluateAll(elements => {
          for (const element of elements) {
            const label = element.getAttribute('aria-label') || element.textContent || '';
            const match = label.match(/^(?:Chapter (\d+) of .*? · )?Page (\d+) of/);
            if (match) return `${match[1] ?? ''}:${match[2]}`;
          }
          return null;
        });
      };
      const initial = await location();
      assert.ok(initial, `${format} must expose its committed location`);
      await mouseSwipe(1);
      assert.notEqual(await location(), initial, `${format} mouse drag must advance the committed page`);
      await mouseSwipe(-1);
      assert.equal(await location(), initial, `${format} reverse mouse drag must restore the initial page`);
      await next.click({ force: true });
      await page.waitForTimeout(500);
      assert.ok(await page.getByRole('button', { name: 'Previous', exact: true }).isEnabled());
      if (process.env.PAPYRUS_SCREENSHOT_DIR) {
        await mkdir(process.env.PAPYRUS_SCREENSHOT_DIR, { recursive: true });
        await page.screenshot({ path: resolve(process.env.PAPYRUS_SCREENSHOT_DIR, `format-${fixture?.replaceAll('/', '-') ?? format}.png`) });
      }
      console.log(`PASS: ${fixture ?? format} rendered viewport, mouse swipes, and navigation`);
    }
    assert.deepEqual(errors, []);
  } finally { await page.close(); }
}

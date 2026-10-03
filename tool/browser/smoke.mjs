import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, extname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const reader = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(reader, 'example/build/web');
await readFile(resolve(dist, 'index.html')); // Build the example first.
const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.ttf': 'font/ttf', '.png': 'image/png', '.svg': 'image/svg+xml' };
const server = createServer(async (request, response) => {
  const path = resolve(dist, `.${decodeURIComponent(new URL(request.url, 'http://local').pathname)}`);
  if (path !== dist && !path.startsWith(dist + sep)) { response.writeHead(403).end(); return; }
  try {
    const file = path === dist ? resolve(dist, 'index.html') : path;
    const bytes = await readFile(file);
    response.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream' });
    response.end(bytes);
  } catch { response.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.PAPYRUS_CHROME_EXECUTABLE });
const temp = await mkdtemp(resolve(tmpdir(), 'papyrus-reader-'));
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 850 } });
  const errors = [];
  let workersClosed = 0;
  page.on('pageerror', error => errors.push(error.message));
  page.on('worker', worker => worker.on('close', () => workersClosed++));
  await page.goto(origin);
  await page.locator('flt-semantics-placeholder').evaluate(element => element.click());

  // Exercise the actual packaged Worker protocol independently of Flutter's
  // widget-test fake clock and mock asset channel.
  const protocol = await page.evaluate(async () => {
    const script = await (await fetch('assets/packages/papyrus_reader/assets/epub_worker.js')).text();
    const url = URL.createObjectURL(new Blob([script], { type: 'text/javascript' }));
    const worker = new Worker(url);
    URL.revokeObjectURL(url);
    let id = 0;
    const pending = new Map();
    worker.onmessage = event => {
      const message = JSON.parse(event.data);
      pending.get(message.id)(message);
      pending.delete(message.id);
    };
    const request = (command, argument) => new Promise((resolve, reject) => {
      const key = ++id;
      const timeout = setTimeout(() => {
        pending.delete(key);
        reject(new Error(`Worker ${command} timed out`));
      }, 15000);
      pending.set(key, message => { clearTimeout(timeout); resolve(message); });
      if (argument instanceof Uint8Array) worker.postMessage({ id: key, command, bytes: argument }, [argument.buffer]);
      else worker.postMessage({ id: key, command, argument });
    });
    const bytes = new Uint8Array(await (await fetch('assets/assets/reading_lab.epub')).arrayBuffer());
    try {
      const opened = await request('open', bytes);
      const chapter = await request('chapter', 0);
      const invalid = await request('open', new Uint8Array([1, 2, 3]));
      return { count: opened.result.count, blocks: chapter.result.blocks.length, error: invalid.error };
    } finally { worker.terminate(); }
  });
  assert.equal(protocol.count, 2);
  assert.ok(protocol.blocks > 20);
  assert.equal(protocol.error, 'invalidDocument');

  await page.getByRole('button', { name: 'Explore layouts', exact: true }).click();
  await page.getByRole('button', { name: 'Next', exact: true }).waitFor();
  await page.waitForFunction(() => document.body.innerText.includes('Passage 1.'));
  await page.getByRole('button', { name: 'Next', exact: true }).click();
  await page.waitForFunction(() => !document.body.innerText.includes('Passage 1. Reading'));
  assert.ok(!await page.locator('body').innerText().then(text => text.includes('After the Rain')),
    'Next must turn a page before crossing chapters');

  const screenshot = async name => {
    if (!process.env.PAPYRUS_SCREENSHOT_DIR) return;
    const folder = resolve(process.env.PAPYRUS_SCREENSHOT_DIR);
    await mkdir(folder, { recursive: true });
    await page.screenshot({ path: resolve(folder, `${name}.png`) });
  };
  const settle = () => page.evaluate(() => new Promise(resolve => {
    let frames = 0;
    const tick = () => ++frames >= 60 ? resolve() : requestAnimationFrame(tick);
    requestAnimationFrame(tick);
  }));
  await settle();
  const passage = /Passage (\d+)\. Reading/.exec(await page.locator('body').innerText());
  assert.ok(passage, 'The next spread must contain readable paragraphs');
  const paragraph = page.getByText(`Passage ${passage[1]}. Reading should feel calm on a small phone and a wide desktop. ` +
    'A page turn keeps its place, while emphasis and meaning remain part of the story. ' +
    'Resize the window or change the typeface to try reflow.', { exact: true }).first();
  const beforeWheel = await paragraph.boundingBox();
  await page.mouse.move(160, 300);
  await page.mouse.wheel(0, 600);
  await settle();
  const afterWheel = await paragraph.boundingBox();
  assert.ok(beforeWheel && afterWheel && Math.abs(beforeWheel.y - afterWheel.y) < 1,
    'A normal paginated column must fit without hidden vertical overflow');
  await screenshot('desktop');
  await page.setViewportSize({ width: 390, height: 844 });
  await settle();
  await page.getByRole('button', { name: 'Reading settings', exact: true }).click();
  await page.getByRole('button', { name: 'Close panel', exact: true }).waitFor();
  await settle();
  await screenshot('mobile-settings');
  await page.mouse.move(190, 650);
  await page.mouse.wheel(0, 600);
  await settle();
  await page.getByLabel('Night', { exact: true }).click();
  await settle();
  await page.getByRole('button', { name: 'Close panel', exact: true }).click();
  await settle();
  await screenshot('mobile-night');
  await page.setViewportSize({ width: 700, height: 360 });
  await settle();
  await screenshot('landscape');
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await page.getByRole('button', { name: 'Open a book', exact: true }).waitFor();
  await settle();

  // File-picker integration lets the example review real documents, including
  // malformed files. Loading errors must keep Back reachable.
  const openFile = async path => {
    const chooser = page.waitForEvent('filechooser');
    // Flutter route transitions do not expose DOM animation state to Playwright.
    // Let the entrance transition finish before sending its next pointer event.
    await settle();
    await page.getByRole('button', { name: 'Open a book', exact: true }).click();
    await settle();
    await (await chooser).setFiles(path);
  };
  await openFile(resolve(reader, 'example/assets/reading_lab.epub'));
  await page.getByRole('button', { name: 'Next', exact: true }).waitFor();
  await page.waitForFunction(() => document.body.innerText.includes('At the Gate'));
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await settle();
  const invalid = resolve(temp, 'invalid.epub');
  await writeFile(invalid, Buffer.from([1, 2, 3]));
  await openFile(invalid);
  await page.getByRole('button', { name: 'Try again', exact: true }).waitFor();
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await settle();
  assert.ok(workersClosed >= 3, 'Document workers must close with their sessions');

  // Crossing chapters must retain keyboard focus without a pointer refocus.
  await page.setViewportSize({ width: 1280, height: 850 });
  await page.getByRole('button', { name: 'Read EPUB', exact: true }).click();
  await page.getByText('At the Gate', { exact: true }).first().waitFor();
  await settle();
  for (let turn = 0; turn < 3; turn++) {
    await page.keyboard.press('ArrowRight');
    await page.getByText('After the Rain', { exact: true }).first().waitFor();
    await settle();
    await page.keyboard.press('ArrowLeft');
    await page.getByText('At the Gate', { exact: true }).first().waitFor();
    await settle();
  }
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await settle();
  await page.setViewportSize({ width: 700, height: 360 });

  await page.getByRole('button', { name: 'Read PDF', exact: true }).click();
  await page.getByRole('button', { name: 'Next', exact: true }).waitFor();
  await settle();
  await screenshot('pdf-initial');
  await page.getByLabel(/Page 1 of 3/).waitFor();
  await settle();
  await page.getByRole('button', { name: 'Next', exact: true }).click();
  await page.getByLabel(/Page 2 of 3/).waitFor();
  await settle();
  await screenshot('pdf');
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await settle();
  await page.getByRole('button', { name: 'Read PDF', exact: true }).click();
  await page.getByLabel(/Page 2 of 3/).waitFor();
  await settle();
  await page.getByRole('button', { name: 'Reading settings', exact: true }).click();
  await page.getByRole('button', { name: 'Close panel', exact: true }).waitFor();
  await settle();
  assert.equal(await page.getByLabel('Typeface', { exact: false }).count(), 0,
    'PDF must not advertise reflowable font controls');

  await page.getByRole('button', { name: 'Close panel', exact: true }).click();
  await settle();
  await page.setViewportSize({ width: 1280, height: 850 });
  await settle();
  await page.getByRole('button', { name: 'Reading settings', exact: true }).click();
  await settle();
  const select = async (current, target) => {
    await page.getByRole('button', { name: new RegExp(current) }).click();
    await settle();
    await page.getByRole('menuitem', { name: target, exact: true }).click();
    await settle();
  };
  await screenshot('pdf-wide-settings');
  await select('Automatic', 'Single');
  await page.getByLabel('Night', { exact: true }).click();
  await settle();
  await screenshot('pdf-night-single');
  const pdfPage = () => page.getByRole('group', { name: 'Page 2', exact: true });
  const singleBefore = await pdfPage().boundingBox();
  assert.ok(singleBefore && singleBefore.x >= 0 && singleBefore.x + singleBefore.width <= 920,
    'Single PDF page must fit the width left by the settings panel');
  await select('Single', 'Double');
  await screenshot('pdf-night-double');
  await select('Double', 'Single');
  const singleAfter = await pdfPage().boundingBox();
  assert.ok(singleAfter && Math.abs(singleBefore.width - singleAfter.width) < 1,
    'Returning to Single must refit instead of retaining spread zoom');
  await page.getByLabel('Light', { exact: true }).click();
  await settle();
  const lightBounds = await pdfPage().boundingBox();
  assert.ok(lightBounds && Math.abs(singleAfter.width - lightBounds.width) < 1,
    'Appearance changes must retain the PDF scale');
  await screenshot('pdf-light-single');
  await page.getByRole('button', { name: 'Close panel', exact: true }).click();
  await settle();
  await page.mouse.move(450, 350);
  await page.mouse.wheel(0, 180);
  await page.getByLabel(/Page 3 of 3/).waitFor();
  await settle();
  await page.mouse.wheel(0, -180);
  await page.getByLabel(/Page 2 of 3/).waitFor();
  await settle();
  await page.getByRole('button', { name: 'Reading settings', exact: true }).click();
  await settle();
  await select('Paginated', 'Continuous scroll');
  await page.getByRole('button', { name: 'Close panel', exact: true }).click();
  await settle();
  // The page semantics group is clipped to the viewport; measure actual text
  // inside it to distinguish scrolling from a stationary viewport container.
  const pdfText = () => page.getByText('Page 2 of 3.', { exact: true });
  const continuousBefore = await pdfText().boundingBox();
  await page.mouse.move(450, 350);
  await page.mouse.wheel(0, 100);
  await settle();
  const continuousAfter = await pdfText().boundingBox();
  assert.ok(continuousBefore && continuousAfter && continuousAfter.y < continuousBefore.y - 5,
    'Continuous PDF mode must move within the page rather than snapping to the next page');
  await page.getByLabel(/Page 2 of 3/).waitFor();
  await screenshot('pdf-continuous');
  await page.getByRole('button', { name: 'Reading settings', exact: true }).click();
  await settle();
  const scrollSingle = await pdfText().boundingBox();
  await select('Single', 'Double');
  await select('Double', 'Single');
  await page.getByLabel('Night', { exact: true }).click();
  await settle();
  const scrollNight = await pdfText().boundingBox();
  assert.ok(scrollSingle && scrollNight && Math.abs(scrollSingle.width - scrollNight.width) < 1,
    'Continuous Single must refit after column changes and preserve scale on Night');
  await screenshot('pdf-continuous-night');
  await page.mouse.move(450, 350);
  await page.mouse.wheel(180, 0);
  await settle();
  const scrollHorizontal = await pdfText().boundingBox();
  assert.ok(scrollHorizontal && Math.abs(scrollHorizontal.x - scrollNight.x) < 1,
    'A width-fitted continuous page must not require horizontal scrolling');

  // Inspect opened popup routes under the opposite app/reader appearance.
  // Closed dropdown text alone cannot detect a stale host canvas color.
  await page.getByRole('button', { name: 'Close panel', exact: true }).click();
  await settle();
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await settle();
  await page.getByRole('button', { name: 'Use dark theme', exact: true }).click();
  await settle();
  await page.getByRole('button', { name: 'Read EPUB', exact: true }).click();
  await page.getByRole('button', { name: 'Reading settings', exact: true }).waitFor();
  await settle();
  await page.getByRole('button', { name: 'Reading settings', exact: true }).click();
  await settle();
  await page.getByLabel('Light', { exact: true }).click();
  await settle();
  await page.getByRole('button', { name: /Reading mode/ }).click();
  await page.getByRole('menuitem', { name: 'Continuous scroll', exact: true }).waitFor();
  await settle();
  await screenshot('dark-app-light-reader-menu');
  await page.getByRole('menuitem', { name: 'Continuous scroll', exact: true }).click();
  await settle();
  await page.getByRole('button', { name: /Typeface/ }).click();
  await page.getByRole('menuitem', { name: 'Sans serif', exact: true }).waitFor();
  await settle();
  await screenshot('dark-app-light-reader-typeface');
  await page.getByRole('menuitem', { name: 'Sans serif', exact: true }).click();
  await settle();
  await page.getByLabel('Night', { exact: true }).click();
  await settle();
  await page.getByRole('button', { name: /Reading mode/ }).click();
  await page.getByRole('menuitem', { name: 'Paginated', exact: true }).waitFor();
  await settle();
  await screenshot('dark-app-night-reader-menu');
  await page.getByRole('menuitem', { name: 'Paginated', exact: true }).click();
  await settle();
  await page.getByRole('button', { name: 'Close panel', exact: true }).click();
  await settle();
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await settle();
  await page.getByRole('button', { name: 'Use light theme', exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log('Browser checks passed: worker protocol, chapter keyboard focus, responsive settings, local files, cleanup, PDF pagination/scroll, column/appearance refitting and opened menus under opposite app themes.');
} finally {
  await browser.close();
  await rm(temp, { recursive: true, force: true });
  await new Promise(resolve => server.close(resolve));
}

// Release-build touch regression. PAPYRUS_PDF_PAGES and PAPYRUS_PDF_CPU_RATE
// increase the fixture size and apply Chromium CPU throttling for local profiling.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, extname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const reader = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = process.env.PAPYRUS_PDF_DIST ?? resolve(reader, 'example/build/web');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.ttf': 'font/ttf' };
const server = createServer(async (request, response) => {
  const path = resolve(dist, `.${decodeURIComponent(new URL(request.url, 'http://local').pathname)}`);
  if (path !== dist && !path.startsWith(dist + sep)) { response.writeHead(403).end(); return; }
  try {
    const file = path === dist ? resolve(dist, 'index.html') : path;
    response.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream' });
    response.end(await readFile(file));
  } catch { response.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch({ executablePath: process.env.PAPYRUS_CHROME_EXECUTABLE });
const temp = await mkdtemp(resolve(tmpdir(), 'papyrus-pdf-swipes-'));

function fixture(pageCount) {
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>', '', '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  const kids = [];
  for (let page = 1; page <= pageCount; page++) {
    const id = objects.length + 1;
    kids.push(`${id} 0 R`);
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents ${id + 1} 0 R >>`);
    let content = `BT /F1 22 Tf 50 780 Td (Swipe page ${page}.) Tj ET\n`;
    for (let i = 0; i < 600; i++) {
      content += `${(i % 7) / 8} ${(page % 5) / 6} ${(i % 3) / 4} rg ${40 + (i % 25) * 20} ${60 + Math.floor(i / 25) * 27} 16 22 re f\n`;
    }
    objects.push(`<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}endstream`);
  }
  objects[1] = `<< /Type /Pages /Count ${pageCount} /Kids [${kids.join(' ')}] >>`;
  let pdf = '%PDF-1.4\n';
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(pdf));
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(pdf);
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets.slice(1)) pdf += `${String(offset).padStart(10, '0')} 00000 n \n`;
  return pdf + `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
}

try {
  const page = await browser.newPage({ viewport: { width: 800, height: 700 }, hasTouch: true });
  page.setDefaultTimeout(15000);
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}`);
  await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
  const book = resolve(temp, 'swipes.pdf');
  await writeFile(book, fixture(Number(process.env.PAPYRUS_PDF_PAGES ?? 40)));
  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Open a book', exact: true }).click();
  await (await chooser).setFiles(book);
  await page.getByText('Swipe page 1.', { exact: true }).waitFor();
  await page.waitForTimeout(1500);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: Number(process.env.PAPYRUS_PDF_CPU_RATE ?? 1) });
  const swipe = async (direction = 1) => {
    const x = direction > 0 ? 720 : 80;
    const point = offset => [{ x: x - direction * offset, y: 350, id: 1 }];
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: point(0) });
    for (let step = 1; step <= 18; step++) {
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: point(step * 35) });
      await page.waitForTimeout(12);
    }
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  };
  await page.evaluate(() => {
    window.swipeMetrics = { gaps: [], tasks: [] };
    let last;
    const tick = now => {
      if (last !== undefined) window.swipeMetrics.gaps.push(now - last);
      last = now;
      window.swipeFrame = requestAnimationFrame(tick);
    };
    window.swipeFrame = requestAnimationFrame(tick);
    window.swipeObserver = new PerformanceObserver(list => {
      window.swipeMetrics.tasks.push(...list.getEntries().map(entry => entry.duration));
    });
    window.swipeObserver.observe({ type: 'longtask', buffered: false });
  });
  for (let turn = 0; turn < 4; turn++) {
    await swipe();
    await page.waitForTimeout(70);
  }
  await page.waitForTimeout(1000);
  const metrics = await page.evaluate(() => {
    cancelAnimationFrame(window.swipeFrame);
    window.swipeObserver.disconnect();
    const { gaps, tasks } = window.swipeMetrics;
    gaps.sort((left, right) => left - right);
    return { frames: gaps.length, p99FrameGapMs: gaps[Math.floor(gaps.length * .99)],
      maxFrameGapMs: gaps.at(-1), framesOver50Ms: gaps.filter(gap => gap > 50).length,
      longTaskCount: tasks.length, maxLongTaskMs: Math.max(0, ...tasks) };
  });
  await page.getByText('Swipe page 5.', { exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ ...metrics, reachedPage: 5 }));
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
  await rm(temp, { recursive: true, force: true });
}

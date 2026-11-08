// Opt-in real-file stress checks. Build example web, serve it, then pass book paths.
// PAPYRUS_STRESS_ORIGIN defaults to http://127.0.0.1:8791.
import { chromium } from 'playwright';
import { basename, resolve } from 'node:path';
import { stat, mkdir, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

const origin = process.env.PAPYRUS_STRESS_ORIGIN ?? 'http://127.0.0.1:8791';
const output = resolve(process.env.PAPYRUS_STRESS_OUTPUT ?? 'stress-results');
await mkdir(output, { recursive: true });
const files = process.argv.slice(2);
if (!files.length) throw new Error('Pass one or more local book paths.');
const results = [];

for (const file of files) {
  const browser = await chromium.launch({ executablePath: process.env.PAPYRUS_CHROME_EXECUTABLE });
  const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
  page.setDefaultTimeout(180000);
  const result = { file: resolve(file), bytes: (await stat(file)).size, errors: [] };
  page.on('pageerror', error => result.errors.push(error.message));
  page.on('crash', () => result.errors.push('Browser page crashed'));
  let closedWorkers = 0;
  page.on('worker', worker => worker.on('close', () => closedWorkers++));
  const system = await browser.newBrowserCDPSession();
  let peakRssKiB = 0;
  let sampling = false;
  const sampleMemory = async () => {
    if (sampling) return;
    sampling = true;
    try {
      const { processInfo } = await system.send('SystemInfo.getProcessInfo');
      const ids = processInfo.map(process => process.id).filter(Number.isInteger);
      const sizes = execFileSync('ps', ['-o', 'rss=', '-p', ids.join(',')], { encoding: 'utf8' });
      peakRssKiB = Math.max(peakRssKiB, sizes.trim().split(/\s+/).reduce((sum, value) => sum + Number(value), 0));
    } catch { /* Process exit races are expected while workers close. */ }
    finally { sampling = false; }
  };
  let memoryTimer;
  let peek;
  const open = async () => {
    const chooser = page.waitForEvent('filechooser');
    await page.getByRole('button', { name: 'Open a book', exact: true }).click();
    await (await chooser).setFiles(resolve(file));
  };
  const monitor = () => page.evaluate(() => {
    window.stressFrames = { gaps: [], tasks: [], last: performance.now() };
    const tick = time => {
      window.stressFrames.gaps.push(time - window.stressFrames.last);
      window.stressFrames.last = time;
      window.stressFrameId = requestAnimationFrame(tick);
    };
    window.stressFrameId = requestAnimationFrame(tick);
    window.stressObserver?.disconnect();
    window.stressObserver = new PerformanceObserver(list => {
      window.stressFrames.tasks.push(...list.getEntries().map(entry => entry.duration));
    });
    window.stressObserver.observe({ type: 'longtask', buffered: false });
  });
  const metrics = () => page.evaluate(() => {
    cancelAnimationFrame(window.stressFrameId);
    window.stressObserver.disconnect();
    const { gaps, tasks } = window.stressFrames;
    gaps.sort((left, right) => left - right);
    return {
      frames: gaps.length,
      maxFrameGapMs: gaps.at(-1) ?? 0,
      p99FrameGapMs: gaps[Math.floor(gaps.length * 0.99)] ?? 0,
      framesOver50Ms: gaps.filter(gap => gap > 50).length,
      longTaskCount: tasks.length,
      maxLongTaskMs: Math.max(0, ...tasks),
    };
  });
  try {
    await page.goto(origin);
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await page.getByRole('button', { name: 'Open a book', exact: true }).waitFor();
    await page.waitForTimeout(1000);
    await monitor();
    await page.waitForTimeout(1500);
    result.idle = await metrics();
    await sampleMemory();
    result.baselineBrowserRssMiB = peakRssKiB / 1024;
    memoryTimer = setInterval(sampleMemory, 500);
    await monitor();
    if (process.env.PAPYRUS_STRESS_CANCEL_ONLY !== '1') {
      const started = Date.now();
      console.log(JSON.stringify({ stage: 'opening', file }));
      await open();
      peek = setTimeout(async () => {
        try { console.log(JSON.stringify({ stage: 'waiting', file, text: (await page.locator('body').innerText()).slice(0, 1500) })); } catch {}
      }, 10000);
      const next = page.getByRole('button', { name: 'Next', exact: true });
      await page.getByLabel('Opening document', { exact: true }).waitFor({ timeout: 10000 });
      await page.getByLabel('Opening document', { exact: true }).waitFor({ state: 'hidden' });
      result.openMs = Date.now() - started;
      await page.waitForTimeout(250);
      result.opening = await metrics();
      if (!await next.isVisible()) await page.keyboard.press('Escape');
      await next.waitFor({ timeout: 5000 });
      clearTimeout(peek);
      console.log(JSON.stringify({ stage: 'opened', ...result }));
      await monitor();
      await next.click({ force: true });
      await page.waitForTimeout(700);
      await page.keyboard.press('ArrowRight');
      await page.waitForTimeout(700);
      result.visibleText = (await page.locator('body').innerText()).slice(0, 1800);
      result.navigation = await metrics();
      await page.screenshot({ path: resolve(output, `${basename(file)}.png`) });
      await monitor();
      if (!await page.getByRole('button', { name: 'Back', exact: true }).isVisible()) await page.keyboard.press('Escape');
      await page.getByRole('button', { name: 'Back', exact: true }).click({ force: true });
      await page.getByRole('button', { name: 'Open a book', exact: true }).waitFor();
      result.close = await metrics();
      result.workersClosedAfterReading = closedWorkers;
      console.log(JSON.stringify({ stage: 'read-and-closed', file }));
    }
    // A second open checks that Back remains usable before preparation finishes.
    await monitor();
    const workerStarted = file.endsWith('.pdf') ? null : page.waitForEvent('worker');
    await open();
    const openingWorker = workerStarted ? await workerStarted : null;
    const workerClosed = openingWorker?.waitForEvent('close', { timeout: 10000 });
    await page.waitForTimeout(100);
    if (!await page.getByRole('button', { name: 'Back', exact: true }).isVisible()) await page.keyboard.press('Escape');
    await page.getByRole('button', { name: 'Back', exact: true }).waitFor({ timeout: 10000 });
    const cancelled = Date.now();
    await page.getByRole('button', { name: 'Back', exact: true }).click({ force: true });
    await page.getByRole('button', { name: 'Open a book', exact: true }).waitFor();
    result.cancelMs = Date.now() - cancelled;
    if (workerClosed) await workerClosed;
    await page.waitForTimeout(500);
    result.cancellation = await metrics();
    result.workersClosedAfterCancel = closedWorkers;
    result.functionalPass = result.errors.length === 0;
  } catch (error) {
    result.functionalPass = false;
    result.failure = String(error);
    try { result.visibleText = (await page.locator('body').innerText({ timeout: 2000 })).slice(0, 3000); } catch {}
    try { result.opening ??= await metrics(); } catch {}
  } finally {
    clearTimeout(peek);
    clearInterval(memoryTimer);
    await sampleMemory();
    result.peakBrowserRssMiB = peakRssKiB / 1024;
    await browser.close();
  }
  results.push(result);
  await writeFile(resolve(output, 'RESULTS.json'), JSON.stringify(results, null, 2) + '\n');
  console.log(JSON.stringify({ stage: 'finished', ...result }));
}
if (results.some(result => !result.functionalPass)) process.exitCode = 1;

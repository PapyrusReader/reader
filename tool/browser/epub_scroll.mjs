import assert from 'node:assert/strict';

export async function checkMobileEpubScroll(browser, origin) {
  const page = await browser.newPage({
    viewport: { width: 390, height: 844 },
    hasTouch: true,
    isMobile: true,
  });
  page.setDefaultTimeout(10000);
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  try {
    await page.goto(origin);
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    const click = async control => {
      await control.waitFor();
      await control.scrollIntoViewIfNeeded();
      await page.waitForTimeout(250);
      const bounds = await control.boundingBox();
      assert.ok(bounds);
      await page.touchscreen.tap(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
    };
    await click(page.getByRole('button', { name: 'Explore layouts', exact: true }));
    await page.getByText('At the Gate', { exact: true }).first().waitFor();
    await page.waitForTimeout(500);
    await page.touchscreen.tap(195, 420);
    const more = page.getByRole('button', { name: 'More reader actions', exact: true });
    if (await more.isVisible()) await click(more);
    await click(page.getByRole('button', { name: 'Reading settings', exact: true }));
    await click(page.getByRole('button', { name: /Paginated/ }));
    await click(page.getByRole('menuitem', { name: 'Continuous scroll', exact: true }));
    await click(page.getByRole('button', { name: 'Close panel', exact: true }));
    const chapter = number => page.getByRole('group', { name: new RegExp(`^Chapter ${number} of 2`) }).first();
    await chapter(1).waitFor();
    const cdp = await page.context().newCDPSession(page);
    const swipe = async (direction, cancel = false) => {
      const start = direction > 0 ? 660 : 240;
      const points = distance => [{ x: 195, y: start - direction * distance, id: 1 }];
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: points(0) });
      for (let step = 1; step <= 12; step++) {
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: points(step * 28) });
        await page.waitForTimeout(20);
      }
      await cdp.send('Input.dispatchTouchEvent', { type: cancel ? 'touchCancel' : 'touchEnd', touchPoints: [] });
      await page.waitForTimeout(500);
    };
    // Set up just inside each boundary; the chapter change itself must use touch.
    await page.mouse.move(20, 420);
    await page.mouse.wheel(0, 100000);
    await page.waitForTimeout(300);
    await page.mouse.wheel(0, -80);
    await page.waitForTimeout(300);
    await swipe(1);
    await chapter(2).waitFor();
    await page.mouse.wheel(0, 80);
    await page.waitForTimeout(300);
    await swipe(-1);
    await chapter(1).waitFor();
    await swipe(1, true);
    await chapter(1).waitFor();
    await swipe(1);
    await chapter(2).waitFor();
    assert.deepEqual(errors, []);
    console.log('PASS: mobile EPUB touch crosses chapter edges, reverses, and ignores cancellation');
  } catch (error) {
    throw new Error(`${error.message}\n${await page.locator('body').ariaSnapshot()}`, { cause: error });
  } finally {
    await page.close();
  }
}

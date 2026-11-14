// Development-only positive control. In an isolated temporary prefix, install the pinned driver:
// npm install --prefix /tmp/stage6-playwright --no-save --no-package-lock playwright-core@1.62.1
// NODE_PATH=/tmp/stage6-playwright/node_modules node native/macos/Stage6Probe/BrowserPointerControl.cjs
// STAGE6_CHROME can override the installed Chrome executable. Chrome runs headless with its sandbox enabled.
const assert = require('node:assert/strict');
const { mkdtemp, readFile, rm, writeFile } = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { randomUUID } = require('node:crypto');
const { chromium } = require('playwright-core');

(async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'stage6-pointer-'));
  let browser;
  try {
    const nonce = `InfiniteDesk-${randomUUID().toUpperCase()}`;
    const template = await readFile(path.join(__dirname, 'BrowserFixture.html'), 'utf8');
    const pagePath = path.join(dir, 'index.html');
    await writeFile(pagePath, template.replaceAll('__STAGE6_NONCE__', nonce));
    browser = await chromium.launch({
      executablePath: process.env.STAGE6_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      headless: true,
      chromiumSandbox: true,
    });
    const page = await browser.newPage();
    await page.goto(pathToFileURL(pagePath).href);
    assert.equal(await page.title(), nonce);
    assert.equal(await page.locator('#result').textContent(), 'Not pressed');
    await page.evaluate(() => {
      window.stage6TrustedClicks = [];
      document.querySelector('button').addEventListener('click', event => {
        window.stage6TrustedClicks.push(event.isTrusted && event.detail > 0);
      });
    });
    for (const count of [1, 2]) {
      await page.getByRole('button', { name: 'Press me' }).click();
      assert.equal(await page.locator('#result').textContent(), `Pressed ${count}`);
      assert.equal(await page.locator('body').getAttribute('data-count'), String(count));
      assert.equal(await page.title(), `${nonce} · Pressed ${count}`);
    }
    assert.deepEqual(await page.evaluate(() => window.stage6TrustedClicks), [true, true]);
    console.log(`PASS: headless Chrome ${browser.version()}, two trusted pointer clicks, dataset/text/title 1 → 2`);
  } finally {
    if (browser) await browser.close();
    await rm(dir, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });

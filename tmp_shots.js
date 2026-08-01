const { chromium } = require("playwright");
const path = require("path");
const fs = require("fs");

const outDir = "/tmp/curiobase-shots";
const copyDir = "/src/plugins/tti-curiobase/tmp/shots";
fs.mkdirSync(outDir, { recursive: true });
fs.mkdirSync(copyDir, { recursive: true });

const pages = [
  { id: 71, name: "deus-ex" },
  { id: 70, name: "archive-doc" },
  { id: 69, name: "google-books" },
  { id: 68, name: "rendlesham-ep" },
  { id: 67, name: "titor-ep" },
  { id: 66, name: "series-hub" },
  { id: 65, name: "primer-film" },
];

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath:
      "/root/.cache/ms-playwright/chromium-1217/chrome-linux64/chrome",
    args: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
  });
  const context = await browser.newContext({
    viewport: { width: 1100, height: 1100 },
    colorScheme: "dark",
  });
  const page = await context.newPage();

  for (const p of pages) {
    const url = `http://127.0.0.1:3000/t/${p.id}`;
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 90000 });
    try {
      await page.waitForSelector(".curiobase-card", { timeout: 20000 });
    } catch (_) {}
    await page.waitForTimeout(1200);

    const info = await page.evaluate(() => {
      const card = document.querySelector(".curiobase-card");
      const stage = document.querySelector(".cb-stage");
      const grav = document.querySelector(".cb-gravity");
      const cs = (el) => (el ? getComputedStyle(el) : null);
      const s = cs(stage);
      const g = cs(grav);
      return {
        hasCard: !!card,
        hasStage: !!stage,
        stageBorderTop: s && s.borderTop,
        stageMarginTop: s && s.marginTop,
        stagePaddingTop: s && s.paddingTop,
        gravBorderTop: g && g.borderTop,
        tokens: card
          ? {
              rule: getComputedStyle(card).getPropertyValue("--cb-rule").trim(),
              gap: getComputedStyle(card).getPropertyValue("--cb-section-gap").trim(),
            }
          : null,
        mediaLink: !!document.querySelector(".cb-media-link"),
        mediaThumb: !!document.querySelector(".cb-media-link-thumb"),
      };
    });
    console.log(`${p.name}: ${JSON.stringify(info)}`);

    const card = page.locator(".curiobase-card").first();
    const dest = `${p.name}.png`;
    if ((await card.count()) > 0) {
      await card.screenshot({ path: path.join(outDir, dest) });
      fs.copyFileSync(path.join(outDir, dest), path.join(copyDir, dest));
      console.log(`shot ${p.name} card`);
    } else {
      await page.screenshot({
        path: path.join(outDir, `${p.name}-full.png`),
        fullPage: false,
      });
      fs.copyFileSync(
        path.join(outDir, `${p.name}-full.png`),
        path.join(copyDir, `${p.name}-full.png`),
      );
      console.log(`shot ${p.name} full (no card)`);
    }
  }

  await browser.close();
  console.log("SHOTS_DONE");
})().catch((e) => {
  console.error(e);
  process.exit(1);
});

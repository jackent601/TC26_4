// Screenshots of the Overview and Availability pages on DEMO, light theme, plus the
// boxes of the regions to annotate (CSS pixels at 1440x900). Run in the official
// Puppeteer image on the compose network: node capture.js http://ui:8080 /out
const puppeteer = require("puppeteer");
const fs = require("fs");

const [base, out] = process.argv.slice(2);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function boxes(page, selectors) {
  return page.evaluate((sels) => {
    const r = {};
    for (const [name, sel] of Object.entries(sels)) {
      const el = typeof sel === "string" ? document.querySelector(sel) : null;
      if (!el) { r[name] = null; continue; }
      const b = el.getBoundingClientRect();
      r[name] = { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) };
    }
    return r;
  }, selectors);
}

(async () => {
  const browser = await puppeteer.launch({ args: ["--no-sandbox"] });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 });
  await page.goto(base + "/", { waitUntil: "networkidle0" });
  await page.evaluate(() => {
    localStorage.setItem("accomm.tenant", "DEMO");
    localStorage.setItem("accomm.theme", "light");
    localStorage.setItem("accomm.nav.collapsed", "0");
  });

  // ------------------------------ Overview ------------------------------
  await page.goto(base + "/overview", { waitUntil: "networkidle0" });
  await wait(800);
  await page.screenshot({ path: out + "/overview.png" });
  const ov = await boxes(page, {
    chart: ".ov-chart",
    toolbar: ".ov-toolbar, .av-toolbar",
    sites: "button[aria-expanded] .filter-label",
    newMenu: "button[aria-label='New']",
    tabs: ".tab-bar",
    panel: ".tab-panel",
    tenant: ".tenant-switch, [aria-label='Tenant']",
    sidebar: "nav",
  });

  // ---------------------------- Availability ----------------------------
  await page.goto(base + "/availability", { waitUntil: "networkidle0" });
  await wait(600);
  // Collapse Floor 2, Floor 3 and Block B so rows show weekly counts as well as bed bars.
  for (const label of ["Collapse Floor 2", "Collapse Floor 3", "Collapse Block B"]) {
    await page.evaluate((l) => {
      const b = [...document.querySelectorAll("button.av-toggle")].find((x) => x.getAttribute("aria-label") === l);
      if (b) b.click();
    }, label);
    await wait(300);
  }
  await wait(800);
  await page.screenshot({ path: out + "/availability.png" });
  const av = await page.evaluate(() => {
    const box = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) }; };
    const visible = (el) => { const b = el.getBoundingClientRect(); return b.bottom > 0 && b.top < innerHeight && b.right > 0 && b.left < innerWidth; };
    const labels = [...document.querySelectorAll(".av-row .av-label")].filter(visible);
    const bar = [...document.querySelectorAll(".av-bar.movable")].filter(visible)[0];
    const week = [...document.querySelectorAll("button.av-week")].filter(visible)[0];
    return {
      toolbar: box(document.querySelector(".av-toolbar")),
      warnings: box(document.querySelector(".av-warnings")),
      grid: box(document.querySelector(".av-scroll")),
      tree: labels.length ? box(labels[0]) : null,
      treeLast: labels.length ? box(labels[labels.length - 1]) : null,
      bar: box(bar), barText: bar && bar.innerText,
      week: box(week),
      newBtn: box(document.querySelector("button[aria-label='New']")),
      axis: box(document.querySelector(".av-axis")),
    };
  });

  fs.writeFileSync(out + "/boxes.json", JSON.stringify({ overview: ov, availability: av }, null, 2));
  await browser.close();
  console.log("captured");
})().catch((e) => { console.error(e); process.exit(1); });

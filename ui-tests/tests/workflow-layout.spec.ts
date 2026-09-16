import { test, expect, type Page } from "@playwright/test";
import { tauriMock } from "./mock-tauri";

async function openWorkflow(page: Page, locale = "en") {
  await page.addInitScript(tauriMock);
  await page.goto(`/?mockLocale=${locale}`);
  await page.locator(".proj-card-main").first().click();
  await page.getByRole("button", { name: locale === "zh" ? "设置" : "Settings", exact: true }).click();
  await page.getByRole("button", { name: locale === "zh" ? "工作流" : "Workflows", exact: true }).click();
  await page.getByTestId("workflow-template-card").filter({ hasText: "Literature evidence review" }).click();
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(3);
}

async function graphBounds(page: Page) {
  return page.getByTestId("workflow-graph-viewport").evaluate((viewport) => {
    const frame = viewport.getBoundingClientRect();
    const canvas = viewport.querySelector('[data-testid="workflow-graph-canvas"]')!.getBoundingClientRect();
    const nodes = [...viewport.querySelectorAll('[data-testid="workflow-graph-node"]')].map(node => node.getBoundingClientRect());
    return {
      centeredX: Math.abs(canvas.left + canvas.width / 2 - frame.left - frame.width / 2),
      centeredY: Math.abs(canvas.top + canvas.height / 2 - frame.top - frame.height / 2),
      inside: nodes.every(node => node.left >= frame.left && node.right <= frame.right && node.top >= frame.top && node.bottom <= frame.bottom),
      ratio: Math.max(canvas.width / frame.width, canvas.height / frame.height),
      nodeWidth: nodes[0].width,
      overflowX: viewport.scrollWidth > viewport.clientWidth,
    };
  });
}

for (const width of [1280, 1920]) {
  test(`workflow fits and centers task cards at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: width === 1280 ? 800 : 1080 });
    await openWorkflow(page);
    await expect.poll(async () => (await graphBounds(page)).inside).toBe(true);
    const bounds = await graphBounds(page);
    expect(bounds.centeredX).toBeLessThan(2);
    expect(bounds.centeredY).toBeLessThan(2);
    expect(bounds.overflowX).toBe(false);
    expect(bounds.nodeWidth).toBeGreaterThan(220);
    expect(bounds.ratio).toBeGreaterThan(.65);
    expect(bounds.ratio).toBeLessThanOrEqual(.91);
    await expect(page.getByTestId("workflow-graph-minimap")).toHaveCount(0);
    await expect(page.getByTestId("workflow-graph-summary")).toContainText("3 tasks · 2 stages · max 2 parallel");
    await expect(page.locator(".workflow-graph-stage-region")).toHaveCount(2);
    await page.locator('[data-node-id="synthesize"]').getByTestId("workflow-graph-node-select").click();
    await expect(page.locator('[data-node-id="synthesize"] .workflow-graph-node-dependencies')).toContainText("supporting_evidence");
    await expect(page.locator(".workflow-graph-edge-group.related")).toHaveCount(2);
    await page.locator('[data-node-id="synthesize"]').getByTestId("workflow-graph-node-select").dblclick();
    await page.getByTestId("dynamic-task-instruction").fill(
      "Synthesize data analysis and literature evidence into an eight-part research design, including assumptions, limitations, and proposed validation.",
    );
    await page.keyboard.press("Escape");
    const cardContent = await page.locator('[data-node-id="synthesize"]').evaluate(node => {
      const instruction = node.querySelector(".workflow-graph-node-instruction")!.getBoundingClientRect();
      const metadata = node.querySelector(".workflow-graph-node-meta")!.getBoundingClientRect();
      const dependencies = node.querySelector(".workflow-graph-node-dependencies")!.getBoundingClientRect();
      return { separated: instruction.bottom <= metadata.top, contained: dependencies.bottom <= node.getBoundingClientRect().bottom - 8 };
    });
    expect(cardContent).toEqual({ separated: true, contained: true });
    await page.mouse.move(0, 0);
    await page.screenshot({ path: testInfo.outputPath(`workflow-${width}.png`), animations: "disabled" });
  });
}

test("fit responds to viewport changes and preserves manual zoom while editing", async ({ page }) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  await openWorkflow(page);
  const fit = page.getByTestId("workflow-graph-fit");
  await page.getByTestId("workflow-graph-zoom-out").click();
  const manual = await fit.innerText();
  await page.getByTestId("workflow-graph-node-select").first().dblclick();
  await page.getByTestId("dynamic-task-instruction").fill("Collect reproducible evidence and report limitations.");
  await expect(fit).toHaveText(manual);
  await page.keyboard.press("Escape");
  await page.setViewportSize({ width: 1280, height: 800 });
  await expect(fit).toHaveText(manual);
  await fit.click();
  await expect.poll(async () => (await graphBounds(page)).inside).toBe(true);
  await page.setViewportSize({ width: 1920, height: 1080 });
  await expect.poll(async () => (await graphBounds(page)).centeredX).toBeLessThan(2);
  await page.getByTestId("workflow-template-card").filter({ hasText: "Roundtable" }).click();
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(5);
  await expect.poll(async () => (await graphBounds(page)).inside).toBe(true);
  await page.getByTestId("workflow-template-card").filter({ hasText: "Literature evidence review" }).click();
  await expect.poll(async () => (await graphBounds(page)).nodeWidth).toBeGreaterThan(280);
});

test("task properties disclose capabilities and preserve form focus", async ({ page }) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  await openWorkflow(page);
  await page.getByTestId("workflow-graph-node-select").first().dblclick();
  const group = page.getByTestId("dynamic-task-capability-group");
  await expect(page.getByTestId("dynamic-task-capabilities")).toBeHidden();
  await expect(page.getByTestId("workflow-capability-summary")).not.toBeEmpty();
  await group.locator(":scope > summary").click();
  const choice = page.getByTestId("dynamic-task-capabilities").getByRole("checkbox").nth(1);
  const checked = await choice.isChecked();
  await choice.setChecked(!checked);
  await expect(choice).toBeChecked({ checked: !checked });
  await expect(group).toHaveAttribute("open", "");
  const instruction = page.getByTestId("dynamic-task-instruction");
  await instruction.fill("Evidence");
  await instruction.press("End");
  await instruction.pressSequentially(" with sources");
  await expect(instruction).toHaveValue("Evidence with sources");
  await expect(instruction).toBeFocused();
  await expect(group).toHaveAttribute("open", "");
  await page.keyboard.press("Escape");
  await page.locator('[data-node-id="synthesize"]').getByTestId("workflow-graph-node-select").dblclick();
  await expect(page.getByTestId("dynamic-task-capabilities")).toBeHidden();
});

test("one add-task entry supports both relationships and Escape closes only the menu", async ({ page }) => {
  await openWorkflow(page);
  await page.getByTestId("workflow-graph-node-select").first().click();
  const toggle = page.getByTestId("workflow-graph-add-menu-toggle");
  await toggle.click();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("workflow-graph-add-menu")).toHaveCount(0);
  await expect(page.getByTestId("workflow-studio")).toBeVisible();
  await expect(page.getByTestId("workflow-graph-add-next")).toHaveCount(0);
  await toggle.click();
  await page.getByTestId("workflow-goal").click();
  await expect(page.getByTestId("workflow-graph-add-menu")).toHaveCount(0);
  await toggle.click();
  await page.getByTestId("workflow-graph-add-after").click();
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(4);
  await expect(page.getByTestId("workflow-graph-edge")).toHaveCount(3);
  await page.keyboard.press("Escape");
  await toggle.click();
  await page.getByTestId("workflow-graph-add-node").click();
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(5);
  await expect(page.getByTestId("workflow-graph-edge")).toHaveCount(3);
  await page.keyboard.press("Escape");
  for (let i = 0; i < 4; i++) {
    await toggle.click();
    await page.getByTestId("workflow-graph-add-node").click();
    await page.keyboard.press("Escape");
  }
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(9);
  await expect(page.getByTestId("workflow-graph-minimap")).toBeVisible();
});


test("dark workflow highlights dependency endpoints and keeps full Agent labels", async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.addInitScript(() => localStorage.setItem("wisp-theme", "dark"));
  await openWorkflow(page);
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  const edge = page.getByTestId("workflow-graph-edge-hit").first();
  await edge.dispatchEvent("mouseenter");
  await page.getByTestId("workflow-graph-edge-group").first().dispatchEvent("mouseenter");
  await expect(page.locator(".workflow-graph-node.related")).toHaveCount(2);
  await expect(page.locator(".workflow-graph-node.dimmed")).toHaveCount(1);
  const labels = await page.locator(".workflow-graph-node-meta code").evaluateAll(nodes =>
    nodes.every(node => node.scrollWidth <= node.clientWidth));
  expect(labels).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("workflow-dark.png"), animations: "disabled" });
});

test("single click shows a summary, double click edits in a modal, and configuration folds", async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  await openWorkflow(page);
  const inspector = page.getByTestId("workflow-graph-inspector");
  const config = page.getByTestId("workflow-studio-config");
  const summary = page.getByTestId("workflow-node-summary");
  const node = page.getByTestId("workflow-graph-node-select").first();
  await expect(inspector).toHaveCount(0);
  await expect(summary).toHaveCount(0);
  await expect(config.getByTestId("workflow-goal")).toBeVisible();
  await expect(page.getByTestId("roundtable-template")).toHaveCount(0);
  const canvasBefore = await page.getByTestId("workflow-graph-viewport").boundingBox();
  const configBefore = await config.boundingBox();
  expect(configBefore!.x).toBeGreaterThanOrEqual(canvasBefore!.x + canvasBefore!.width - 1);
  await page.screenshot({ path: testInfo.outputPath("workflow-default.png"), animations: "disabled" });
  await node.click();
  await expect(summary).toContainText("supporting_evidence");
  await expect(inspector).toHaveCount(0);
  await expect(page.getByTestId("dynamic-task-instruction")).toHaveCount(0);
  expect(await page.getByTestId("workflow-graph-viewport").boundingBox()).toEqual(canvasBefore);
  const summaryBox = await summary.boundingBox();
  expect(summaryBox!.x).toBe(configBefore!.x);
  expect(summaryBox!.y).toBeGreaterThan(configBefore!.y);
  await config.locator(":scope > summary").click();
  await expect(config.getByTestId("workflow-goal")).toBeHidden();
  await expect(summary).toBeVisible();
  expect(await page.getByTestId("workflow-graph-viewport").boundingBox()).toEqual(canvasBefore);
  await config.locator(":scope > summary").click();
  await page.screenshot({ path: testInfo.outputPath("workflow-summary.png"), animations: "disabled" });
  await node.dblclick();
  await expect(inspector).toHaveAttribute("role", "dialog");
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(3);
  await page.keyboard.press("Escape");
  await expect(inspector).toHaveCount(0);
  await expect(summary).toBeVisible();
  await expect(node).toBeFocused();
  await page.getByTestId("workflow-node-edit").click();
  await page.getByTestId("dynamic-task-instruction").fill("Updated evidence instructions");
  await expect(inspector).toHaveCSS("opacity", "1");
  await expect(page.getByTestId("workflow-node-overlay")).toHaveCSS("opacity", "1");
  await page.screenshot({ path: testInfo.outputPath("workflow-node-modal.png"), animations: "disabled" });
  await page.getByTestId("workflow-inspector-close").click();
  await expect(summary).toContainText("Updated evidence instructions");
  await page.getByTestId("workflow-graph-add-menu-toggle").click();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("workflow-graph-add-menu")).toHaveCount(0);
  await expect(summary).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(summary).toHaveCount(0);
  await expect(page.getByTestId("workflow-studio")).toBeVisible();
});

test("one New workflow button offers blank, templates and Skills without changing the draft on cancel", async ({ page }, testInfo) => {
  await openWorkflow(page);
  await page.getByTestId("workflow-name").fill("Unsaved draft");
  const create = page.getByTestId("workflow-new");
  await expect(page.locator(".workflow-studio-library-actions button")).toHaveCount(1);
  await create.click();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("workflow-new-dialog")).toHaveCount(0);
  await expect(page.getByTestId("workflow-name")).toHaveValue("Unsaved draft");
  await expect(create).toBeFocused();
  await create.click();
  await expect(page.getByTestId("workflow-new-use-template")).toBeVisible();
  await expect(page.getByTestId("workflow-new-scratch")).toBeVisible();
  await expect(page.getByTestId("portfolio-planner-open")).toBeVisible();
  await expect(page.getByTestId("workflow-new-dialog")).toHaveCSS("opacity", "1");
  await page.screenshot({ path: testInfo.outputPath("workflow-new.png"), animations: "disabled" });
  await page.getByTestId("workflow-new-use-template").click();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("workflow-new-dialog")).toHaveCount(0);
  await expect(page.getByTestId("workflow-name")).toHaveValue("Unsaved draft");
  await create.click();
  await page.getByTestId("workflow-new-use-template").click();
  await page.getByTestId("workflow-new-template").filter({ hasText: "Roundtable" }).click();
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(5);
  await expect(page.getByTestId("workflow-save")).toHaveText("Save Workflow");
  await expect(page.getByTestId("workflow-graph-inspector")).toHaveCount(0);
  await create.click();
  await page.getByTestId("workflow-new-scratch").click();
  await expect(page.getByTestId("workflow-name")).toHaveValue("");
  await expect(page.getByTestId("workflow-goal")).toHaveValue("");
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(1);
  await expect(page.getByTestId("workflow-graph-inspector")).toHaveCount(0);
});

test("canvas settles with classic scrollbars across fit, zoom and viewport sizes", async ({ page }) => {
  await openWorkflow(page);
  // Force non-overlay scrollbars, as on Windows WebView2. Overlay scrollbars
  // hide this regression because their appearance does not consume space.
  await page.addStyleTag({ content: `
    .workflow-graph-viewport { width: calc(100% - .3px); max-height: calc(100% - 48.3px); }
    .workflow-graph-viewport::-webkit-scrollbar { width: 17px; height: 17px; }
  ` });
  for (const size of [{ width: 1280, height: 800 }, { width: 1920, height: 1080 }, { width: 3840, height: 2160 }]) {
    await page.setViewportSize(size);
    await page.getByTestId("workflow-graph-fit").click();
    const samples = await page.getByTestId("workflow-graph-viewport").evaluate(async viewport => {
      const samples: string[] = [];
      for (let frame = 0; frame < 100; frame++) {
        await new Promise<void>(resolve => requestAnimationFrame(() => resolve()));
        samples.push(JSON.stringify({
          width: viewport.clientWidth, height: viewport.clientHeight,
          scrollWidth: viewport.scrollWidth, scrollHeight: viewport.scrollHeight,
          zoom: document.querySelector('[data-testid="workflow-graph-fit"]')!.textContent,
        }));
      }
      return samples;
    });
    expect(new Set(samples.slice(20)).size).toBe(1);
    const last = JSON.parse(samples.at(-1)!);
    expect(last.scrollWidth).toBe(last.width);
    expect(last.scrollHeight).toBe(last.height);
  }
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.getByTestId("workflow-graph-fit").click();
  await expect.poll(async () => Number((await page.getByTestId("workflow-graph-fit").innerText()).replace("%", ""))).toBeLessThan(140);
  const zoomIn = page.getByTestId("workflow-graph-zoom-in");
  while (await zoomIn.isEnabled()) await zoomIn.click();
  await expect.poll(async () => (await graphBounds(page)).overflowX).toBe(true);
  await page.getByTestId("workflow-graph-viewport").evaluate(viewport => {
    viewport.scrollLeft = viewport.scrollWidth;
  });
  await expect.poll(() => page.getByTestId("workflow-graph-viewport").evaluate(v => v.scrollLeft)).toBeGreaterThan(0);
  await page.getByTestId("workflow-graph-fit").click();
  await expect.poll(async () => (await graphBounds(page)).overflowX).toBe(false);
  await expect.poll(() => page.getByTestId("workflow-graph-viewport").evaluate(v => v.scrollLeft)).toBe(0);
});

for (const width of [640, 1600]) {
  test(`Chinese workflow creation and node modal remain usable at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    await openWorkflow(page, "zh");
    if (width === 640) await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"));
    await page.getByTestId("workflow-new").click();
    const create = page.getByTestId("workflow-new-dialog");
    await expect(create.getByRole("button", { name: /^空白/ })).toBeVisible();
    await expect(create.getByRole("button", { name: /^基于模板/ })).toBeVisible();
    await expect(create.getByRole("button", { name: /^基于 Skill/ })).toBeVisible();
    await expect(create).toHaveCSS("opacity", "1");
    const createBounds = await create.boundingBox();
    expect(createBounds!.x).toBeGreaterThanOrEqual(0);
    expect(createBounds!.x + createBounds!.width).toBeLessThanOrEqual(width);
    await page.screenshot({ path: testInfo.outputPath(`workflow-new-zh-${width}.png`), animations: "disabled" });
    await page.keyboard.press("Escape");
    await page.getByTestId("workflow-graph-node-select").first().dblclick();
    const editor = page.getByTestId("workflow-graph-inspector");
    await expect(editor).toHaveCSS("opacity", "1");
    const bounds = await editor.boundingBox();
    expect(bounds!.x).toBeGreaterThanOrEqual(0);
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width);
    expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(900);
    await expect(editor.getByTestId("dynamic-task-instruction")).toBeVisible();
    await editor.getByTestId("dynamic-task-instruction").fill("验证证据来源与结论。");
    await page.screenshot({ path: testInfo.outputPath(`workflow-editor-zh-${width}.png`), animations: "disabled" });
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("workflow-node-summary")).toContainText("验证证据来源与结论。");
  });
}

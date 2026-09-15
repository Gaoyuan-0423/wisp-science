import { test, expect, type Page } from "@playwright/test";
import { tauriMock } from "./mock-tauri";

async function openWorkflow(page: Page) {
  await page.addInitScript(tauriMock);
  await page.goto("/");
  await page.locator(".proj-card-main").first().click();
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.getByRole("button", { name: "Workflows", exact: true }).click();
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
    await page.getByTestId("dynamic-task-instruction").fill(
      "Synthesize data analysis and literature evidence into an eight-part research design, including assumptions, limitations, and proposed validation.",
    );
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
  await page.getByTestId("dynamic-task-instruction").fill("Collect reproducible evidence and report limitations.");
  await expect(fit).toHaveText(manual);
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
  await page.locator('[data-node-id="synthesize"]').getByTestId("workflow-graph-node-select").click();
  await expect(page.getByTestId("dynamic-task-capabilities")).toBeHidden();
});

test("one add-task entry supports both relationships and Escape closes only the menu", async ({ page }) => {
  await openWorkflow(page);
  const toggle = page.getByTestId("workflow-graph-add-menu-toggle");
  await toggle.click();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("workflow-graph-add-menu")).toHaveCount(0);
  await expect(page.getByTestId("workflow-studio")).toBeVisible();
  await expect(page.getByTestId("workflow-graph-add-next")).toHaveCount(0);
  await toggle.click();
  await page.getByTestId("dynamic-task-id").click();
  await expect(page.getByTestId("workflow-graph-add-menu")).toHaveCount(0);
  await toggle.click();
  await page.getByTestId("workflow-graph-add-after").click();
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(4);
  await expect(page.getByTestId("workflow-graph-edge")).toHaveCount(3);
  await toggle.click();
  await page.getByTestId("workflow-graph-add-node").click();
  await expect(page.getByTestId("workflow-graph-node")).toHaveCount(5);
  await expect(page.getByTestId("workflow-graph-edge")).toHaveCount(3);
  for (let i = 0; i < 4; i++) {
    await toggle.click();
    await page.getByTestId("workflow-graph-add-node").click();
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

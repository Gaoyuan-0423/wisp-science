import { test, expect, type Page } from "@playwright/test";
import { parallelMock } from "./mock-tauri";

async function queueWithDelayedAcceptance(page: Page) {
  await page.addInitScript(parallelMock);
  await page.goto("/");
  await page.locator(".proj-card-main").first().click();
  await page.locator("#composer-input").fill("alpha");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await expect(page.getByRole("button", { name: "Queue…", exact: true })).toBeVisible();
  await page.evaluate(() => {
    const win = window as any;
    const core = win.__TAURI__.core;
    const invoke = core.invoke;
    win.__queueOrder = [];
    core.invoke = async (cmd: string, args: any) => {
      if (cmd === "enqueue_turn") {
        win.__queueOrder.push("enqueue-started");
        await new Promise<void>((resolve, reject) => {
          win.__releaseEnqueue = resolve;
          win.__rejectEnqueue = () => reject(new Error("queue unavailable"));
        });
        win.__queueOrder.push("enqueue-accepted");
        return null;
      }
      if (cmd === "queued_turn_action") {
        win.__queueOrder.push(args instanceof Map ? args.get("action") : args.action);
        if (win.__queueActionError) throw new Error(win.__queueActionError);
        return null;
      }
      return invoke(cmd, args);
    };
  });
  await page.locator("#composer-input").fill("Use the revised question");
  await page.getByRole("button", { name: "Queue…", exact: true }).click();
  return page.locator(".msg.user.queued", { hasText: "Use the revised question" });
}

test("Guide now waits for the queued message to be accepted by the backend", async ({ page }) => {
  const row = await queueWithDelayedAcceptance(page);
  await row.getByRole("button", { name: "Guide now", exact: true }).click();
  expect(await page.evaluate(() => (window as any).__queueOrder)).toEqual(["enqueue-started"]);
  await page.evaluate(() => (window as any).__releaseEnqueue());
  await expect.poll(() => page.evaluate(() => (window as any).__queueOrder))
    .toEqual(["enqueue-started", "enqueue-accepted", "cutin"]);
});

test("failed enqueue never dispatches a waiting Guide now action", async ({ page }) => {
  const row = await queueWithDelayedAcceptance(page);
  await row.getByRole("button", { name: "Guide now", exact: true }).click();
  await page.evaluate(() => (window as any).__rejectEnqueue());
  await expect(row).toHaveCount(0);
  await expect(page.locator(".topbar .hint")).toContainText("queue unavailable");
  expect(await page.evaluate(() => (window as any).__queueOrder)).toEqual(["enqueue-started"]);
});

test("Guide now reports command failure and leaves its queued message available", async ({ page }) => {
  const row = await queueWithDelayedAcceptance(page);
  await page.evaluate(() => {
    (window as any).__queueActionError = "guidance unavailable";
    (window as any).__releaseEnqueue();
  });
  await row.getByRole("button", { name: "Guide now", exact: true }).click();
  await expect(page.locator(".topbar .hint")).toContainText("Queue action failed: guidance unavailable");
  await expect(row).toBeVisible();
  await page.evaluate(() => { (window as any).__queueActionError = null; });
  await row.getByRole("button", { name: "Guide now", exact: true }).click();
  await expect.poll(() => page.evaluate(() => (window as any).__queueOrder))
    .toEqual(["enqueue-started", "enqueue-accepted", "cutin", "cutin"]);
  await expect(page.locator(".topbar .hint")).toHaveCount(0);
});

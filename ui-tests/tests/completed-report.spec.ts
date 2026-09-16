import { test, expect } from "@playwright/test";
import { tauriMock } from "./mock-tauri";

for (const width of [1280, 540]) {
  test(`completed report folds recorded phases across usage and compaction at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.addInitScript(tauriMock);
    await page.goto("/");
    await expect.poll(() => page.evaluate(() => Boolean((window as any).__tauriListenerReady?.("open-session")))).toBe(true);
    await page.evaluate(() => {
      const w = window as any;
      const invoke = w.__TAURI__.core.invoke;
      const usage = { role: "usage", text: JSON.stringify({ input: 100, output: 10 }) };
      w.__TAURI__.core.invoke = async (cmd: string, args: any) => {
        const id = args instanceof Map ? args.get("id") : args?.id;
        if (cmd === "load_session" && id === "phase-report") return {
          items: [
            { role: "user", text: "Analyze the trajectory and write a report" },
            ...Array.from({ length: 6 }, (_, phase) => [
              { role: "assistant", text: `Checking phase ${phase + 1}` },
              { role: "reasoning", text: `Reasoning for phase ${phase + 1}` },
              { role: "tool", tool_name: "python", ok: true, input: "analyze()", text: `Phase ${phase + 1} results`, duration_ms: 50 },
              usage,
              ...(phase === 2 ? [{ role: "compaction", text: JSON.stringify({ before: 1000, after: 500, strategy: "auto" }) }] : []),
            ]).flat(),
            { role: "tool", tool_name: "update_plan", ok: true, input: "", text: JSON.stringify({ plan: [{ step: "Write report", status: "completed" }] }) },
            { role: "assistant", text: "## Final trajectory report\n\nAnalysis complete. The figures and methods are ready." },
            usage,
          ], next_before_seq: null, user_offset: 0,
        };
        return invoke(cmd, args);
      };
      w.__tauriEmit("open-session", { projectId: "other", sessionId: "phase-report" });
    });
    const report = page.getByRole("heading", { name: "Final trajectory report" });
    await expect(report).toBeVisible();
    const activity = page.locator(".activity-summary");
    await expect(activity).toHaveCount(1);
    const head = activity.locator(".steps-head");
    await expect(head).toHaveAttribute("aria-expanded", "false");
    await expect(activity.locator(".steps-body")).toHaveCount(0);
    await expect(page.locator(".thread > .usage-row")).toHaveCount(1);
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: `test-results/completed-report-${width}.png`, fullPage: true, animations: "disabled" });
    await head.click();
    await expect(activity.locator(".step-progress")).toHaveCount(6);
    await expect(activity.locator(".usage-row")).toHaveCount(6);
    await expect(activity.getByTestId("context-compaction-flag")).toBeVisible();
    await expect(activity.locator(".execution-plan")).toBeVisible();
    await expect(activity.locator(".step-name")).toContainText([
      "progress", "thinking", "python", "progress", "thinking", "python",
      "progress", "thinking", "python", "progress", "thinking", "python",
      "progress", "thinking", "python", "progress", "thinking", "python",
    ]);
    await head.click();
    await expect(report).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
}

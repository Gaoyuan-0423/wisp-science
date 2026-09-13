import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { tauriMock } from "./mock-tauri";

// Capture the real frontend with local fixture data; never call a model.
for (const locale of ["zh", "en"] as const) {
  test(`specialists and quick actions tutorial (${locale})`, async ({ page }, info) => {
    const tr = (zh: string, en: string) => locale === "zh" ? zh : en;
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.addInitScript(tauriMock);
    await page.goto(`/?mockLocale=${locale}`);
    await page.locator(".proj-card-main").first().click();
    await expect(page.locator("#composer-input")).toBeVisible();
    await page.getByRole("button", { name: tr("设置", "Settings"), exact: true }).click();
    const nav = page.locator(".settings-nav");
    const shot = async (name: string) => {
      await page.evaluate(async () => { await document.fonts.ready; });
      const relative = `${locale === "en" ? "en/" : ""}${name}.png`;
      const path = process.env.WISP_TUTORIAL_SHOTS
        ? resolve(process.env.WISP_TUTORIAL_SHOTS, relative) : info.outputPath(relative);
      mkdirSync(dirname(path), { recursive: true });
      await page.screenshot({ path, animations: "disabled" });
    };

    await nav.getByRole("button", { name: tr("专家", "Specialists"), exact: true }).click();
    await expect(page.getByText("Scientific Illustrator", { exact: true })).toBeVisible();
    await page.getByText(tr("新建专家", "Add specialist"), { exact: true }).click();
    const scratch = page.getByRole("button", { name: tr("从零开始", "Write from scratch") });
    await expect(scratch).toBeVisible();
    // The Chinese article uses the original user-supplied screenshot.
    if (locale === "en") await shot("specialists/01-overview");
    await page.keyboard.press("Escape");
    await expect(scratch).not.toBeVisible();
    await expect(page.locator(".settings-page")).toBeVisible();

    await nav.getByRole("button", { name: tr("快捷动作", "Quick Actions"), exact: true }).click();
    await expect(page.getByTestId("quick-action-row").first()).toBeVisible();
    await shot("quick-actions/01-settings");
    await page.getByTestId("quick-action-new").click();
    await page.getByTestId("quick-action-name").fill(tr("讨论这段观点", "Discuss this claim"));
    await page.getByTestId("quick-action-workflow").selectOption({ label: "Roundtable" });
    await expect(page.getByTestId("quick-action-save")).toBeEnabled();
    await shot("quick-actions/02-create");
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("quick-action-form")).toHaveCount(0);
    await expect(page.getByTestId("quick-actions-settings")).toBeVisible();
  });
}

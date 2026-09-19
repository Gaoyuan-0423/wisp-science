import { expect, test, type Page } from "@playwright/test";
import { tauriMock } from "./mock-tauri";

function compactionPayload(overrides: Record<string, unknown> = {}) {
  return {
    before: 1000,
    after: 200,
    strategy: "manual",
    epoch: 1,
    checkpoint: "[context summary checkpoint]\n\nFolded older turns.",
    kept_from_user_index: 1,
    undone: false,
    can_undo: true,
    ...overrides,
  };
}

async function lastInvokeArgs(page: Page, cmd: string) {
  return page.evaluate((name) => {
    const plain = (value: any): any => {
      if (value instanceof Map) return Object.fromEntries([...value].map(([k, v]) => [k, plain(v)]));
      if (Array.isArray(value)) return value.map(plain);
      if (value && typeof value === "object") {
        return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, plain(v)]));
      }
      return value;
    };
    const calls = ((window as any).__skillInvokeLog ?? []).filter((c: any) => c.cmd === name);
    return plain(calls.at(-1)?.args ?? null);
  }, cmd);
}

async function openCompactedSession(page: Page, payload = compactionPayload()) {
  await page.addInitScript(tauriMock);
  await page.addInitScript((item) => {
    (window as any).__compactionItem = item;
  }, payload);
  await page.goto("/");
  await expect.poll(() =>
    page.evaluate(() => Boolean((window as any).__tauriListenerReady?.("open-session"))),
  ).toBe(true);
  await page.evaluate(() => {
    const w = window as any;
    const original = w.__TAURI__.core.invoke;
    w.__TAURI__.core.invoke = async (cmd: string, args: any) => {
      const arg = (key: string) => args instanceof Map ? args.get(key) : args?.[key];
      if (cmd === "load_session" && arg("id") === "s-compact") {
        return {
          items: [
            { role: "user", text: "first question" },
            { role: "assistant", text: "first answer" },
            { role: "user", text: "second question" },
            { role: "assistant", text: "second answer" },
            { role: "compaction", text: JSON.stringify(w.__compactionItem) },
          ],
          next_before_seq: null,
          user_offset: 0,
          outline: [
            { user_index: 0, text: "first question" },
            { user_index: 1, text: "second question" },
          ],
        };
      }
      return original(cmd, args);
    };
  });
  await page.evaluate(() =>
    (window as any).__tauriEmit("open-session", { projectId: "default", sessionId: "s-compact" }),
  );
  await expect(page.getByTestId("context-compaction-flag")).toBeVisible();
}

test("compaction row expands the checkpoint and Escape closes only that layer", async ({ page }) => {
  await openCompactedSession(page);
  await page.getByTestId("conversation-outline-toggle").click();
  await expect(page.getByTestId("conversation-outline")).toBeVisible();
  await page.getByTestId("context-compaction-expand").click();
  const details = page.getByTestId("context-compaction-details");
  await expect(details).toBeVisible();
  await expect(details).toContainText("Folded older turns.");
  await expect(details).toContainText("Epoch 1");
  await expect(details).toContainText("Kept from turn 2");
  await page.keyboard.press("Escape");
  await expect(details).toHaveCount(0);
  await expect(page.getByTestId("conversation-outline")).toBeVisible();
});

test("undo compaction invokes the command and marks the row undone", async ({ page }) => {
  await openCompactedSession(page);
  await page.getByTestId("context-compaction-expand").click();
  await page.getByTestId("undo-compaction").click();
  await expect.poll(() => lastInvokeArgs(page, "undo_compaction")).toMatchObject({
    sessionId: "s-compact",
  });
  const flag = page.getByTestId("context-compaction-flag");
  await expect(flag).toHaveAttribute("data-undone", "true");
  await expect(flag).toContainText("Compaction undone");
});

test("new turns disable undo and show the backend reason", async ({ page }) => {
  await openCompactedSession(page, compactionPayload({
    can_undo: false,
    undo_reason: "has_new_turns",
  }));
  await page.getByTestId("context-compaction-expand").click();
  const undo = page.getByTestId("undo-compaction");
  await expect(undo).toBeDisabled();
  await expect(undo).toHaveAttribute("title", "Conversation continued after compaction");
});

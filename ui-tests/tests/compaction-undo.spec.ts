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
      if (cmd === "load_session_context_view" && (arg("sessionId") === "s-compact" || arg("id") === "s-compact")) {
        (w.__skillInvokeLog ??= []).push({ cmd, args });
        return [
          { role: "system", text: "You are wisp-science", kind: "system" },
          { role: "checkpoint", text: "[context summary checkpoint]\n\nFolded older turns.", kind: "checkpoint" },
          { role: "user", text: "second question" },
          { role: "assistant", text: "second answer" },
        ];
      }
      if (cmd === "load_session" && arg("id") === "s-compact") {
        return {
          items: [
            { role: "user", text: "first question" },
            { role: "assistant", text: "first answer" },
            { role: "user", text: "second question" },
            { role: "assistant", text: "second answer" },
            { role: "usage", text: JSON.stringify({ input: 80, output: 20, ctx_tokens: 200, max_context: 1000 }) },
            { role: "compaction", text: JSON.stringify(w.__compactionItem) },
          ],
          next_before_seq: null,
          user_offset: 0,
          outline: [
            { user_index: 0, text: "first question" },
            { user_index: 1, text: "second question" },
          ],
          head_epoch: 1,
          in_context_from_user_index: 1,
          context_epochs: [{
            epoch: 1,
            parent_epoch: 0,
            strategy: "manual",
            kind: "semantic",
            before_tokens: 1000,
            after_tokens: 200,
            initial_head_seq: 9,
            first_kept_seq: 4,
            checkpoint_seq: 7,
            has_new_turns: false,
          }],
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

test("compacted bubbles are marked out of context and model view is read-only", async ({ page }) => {
  await openCompactedSession(page);
  const first = page.locator("[data-user-index='0']").first();
  const second = page.locator("[data-user-index='1']").first();
  await expect(first).toHaveAttribute("data-in-context", "false");
  await expect(first).toHaveAttribute("title", "Not in the current context; represented by the summary");
  await expect(second).toHaveAttribute("data-in-context", "true");
  await expect(
    page.locator("[data-testid='transcript-item']").filter({
      has: page.getByTestId("context-compaction-flag"),
    }),
  ).toHaveAttribute("data-in-context", "true");

  await page.getByTestId("transcript-view-model").click();
  await expect.poll(() => lastInvokeArgs(page, "load_session_context_view")).toMatchObject({
    sessionId: "s-compact",
  });
  await expect(page.locator(".thread")).toHaveAttribute("data-model-view", "true");
  const thread = page.locator(".thread");
  await expect(page.getByTestId("context-system-row")).toBeVisible();
  await expect(page.getByTestId("context-checkpoint-row")).toContainText("Folded older turns.");
  await expect(thread.getByText("second question")).toBeVisible();
  await expect(thread.getByText("first question")).toHaveCount(0);
  await expect(thread.getByRole("button", { name: "Rewind" })).toHaveCount(0);
  await expect(thread.getByRole("button", { name: "Branch" })).toHaveCount(0);

  await page.getByTestId("transcript-view-full").click();
  await expect(thread).toHaveAttribute("data-model-view", "false");
  await expect(thread.getByText("first question")).toBeVisible();
  await expect(page.getByTestId("context-system-row")).toHaveCount(0);

  await page.getByTestId("context-usage-trigger").click();
  const panel = page.getByTestId("context-usage-panel");
  await expect(panel.getByTestId("context-usage-epoch")).toHaveText(
    "Epoch 1 · system + checkpoint + 1 kept turns",
  );
});

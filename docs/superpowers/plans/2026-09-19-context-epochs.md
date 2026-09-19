# 上下文纪元（话中话）实施计划

> 设计依据：[上下文纪元设计](../specs/2026-09-19-context-epochs-design.md)
>
> 对应 Issue：[#1253](https://github.com/xuzhougeng/wisp-science/issues/1253)（评论区「Compact 之后：画面、分支、回溯、探索」）；顺带解决 [#973](https://github.com/xuzhougeng/wisp-science/issues/973)

## 交付策略

按小 PR 交付，每个 PR 只加一个持久抽象或一个可测行为。前四个 PR 构成「压缩可反悔」MVP（旧上下文不动、回溯 / 分支 / 探索可回到压缩前任一轮）；PR 5–6 交付「压缩透明」（撤销压缩、看见 checkpoint、模型视角）。

每个行为变更都必须带测试。涉及 UI / Tauri 的 PR 除窄测试外还要跑 WASM check 与 Playwright；MVP 与最终交付各跑一次仓库全套验证。任何一步都不需要真实模型、网络或 SSH：压缩摘要用现有 fake provider，Store 用临时目录 SQLite。

### 与 #1253 的关系

#1253 正文的三刀（压缩目标按 `context - max_tokens`、prune 折叠旧 `tool_calls.arguments`、手动 / overflow 必须落到工作集）是独立修复，不在本计划内。两者可以任意先后：

- 若 #1253 先落地、本计划 PR 3 未落地：按 issue 评论建议临时加 fail-closed 阀（检测到 `[context summary checkpoint]` 且目标轮不在 tail 时拒绝 branch / rewind）。本计划 PR 3 删除该阀。
- 若本计划先落地：#1253 不需要那道阀。

### 全局约束

- 迁移全部幂等，走 `crates/wisp-store/src/lib.rs` 的 `has_column` / `CREATE TABLE IF NOT EXISTS` 模式。
- `seq` 永不重编号；任何「index 当 seq」的假设在触碰到的 PR 内一并消除。
- 不新增 `.wisp/history` 格式或 `wisp-history:` 解析的改动。
- 新弹层进入 window 级 Escape 栈；图标只走 `compose_icon()`。
- 跨边界新增类型全部放 `crates/wisp-dto`，并在 `src-tauri/src/dto_contract_tests.rs` 加反序列化用例。

## PR 1：Schema、Store API 与 `load_messages` 语义（无行为变化）

**用户问题：** 先让「一个 frame 有多份上下文」在数据层成立，同时不改任何现有行为。

### 修改

- `crates/wisp-store/migrations/0000_init.sql`：新库直接带 `messages.epoch`、`frames.head_epoch`、`context_epochs`、索引。
- `crates/wisp-store/src/lib.rs`：旧库幂等补列 / 补表；所有既有行 `epoch=0`、`head_epoch=0`。
- `crates/wisp-store/src/sessions.rs`：
  - `load_messages` / `load_messages_with_seq` 只返回 `epoch = head_epoch`。
  - 新增 `load_messages_in_epoch`、`load_messages_all_epochs`。
  - `replace_messages` 追加：删除 `context_epochs`、`head_epoch=0`、新行 `epoch=0`。文档注释改为「仅用于从零建立 epoch 0（导入 / seed / exploration clone）；压缩不再走这里」。
  - `insert_message_row` 带 `epoch` 参数；`append_message` 写入 head 纪元。
- 新建 `crates/wisp-store/src/context_epochs.rs`：`ContextEpochRecord`、`open_context_epoch`、`context_epochs(frame)`、`resolve_message_epoch(frame, seq)`。
- `crates/wisp-store/src/models.rs`：导出 `ContextEpochRecord`。
- `load_messages` 调用方审计（本 PR 只改语义确实需要全纪元的两处，其余保持 head）：
  - `crates/wisp-store/src/research_archives.rs`：导出 / 导入改为全纪元，带 `epoch` 与 `head_epoch`，保证无损往返。
  - `crates/wisp-store/src/project_transfer.rs`：确认 `messages` 拷贝带 `epoch` 列、`frames` 拷贝带 `head_epoch`。
  - `src-tauri/src/delegation_runtime.rs`：`load_messages().len() + 1` 改为 `max_message_seq() + 1`。
  - 其余（`memory_commands`、`debug_request`、`session_export`、`trajectory_export`、`channels`、`specialists`、`acp`、`side_chat`、`turn_undo`、`project_reader`）保持 head 语义，逐个确认注释无歧义。

### 接口

```rust
pub struct ContextEpochRecord {
    pub frame_id: String,
    pub epoch: i64,
    pub parent_epoch: i64,
    pub strategy: String,          // manual | auto | overflow
    pub kind: String,              // prune_only | semantic
    pub before_tokens: i64,
    pub after_tokens: i64,
    pub first_seq: i64,
    pub initial_head_seq: i64,
    pub checkpoint_seq: Option<i64>,
    pub first_kept_seq: Option<i64>,
    pub archive_ref: Option<String>,
    pub ui_event_seq: Option<i64>,
    pub created_at: i64,
}

pub struct OpenContextEpoch<'a> {
    pub messages: &'a [Message],
    pub strategy: &'a str,
    pub kind: &'a str,
    pub before_tokens: usize,
    pub after_tokens: usize,
    pub archive_ref: Option<&'a str>,
    pub ui_event_seq: Option<i64>,
    pub first_kept_seq: Option<i64>,
}

impl Store {
    pub async fn frame_head_epoch(&self, frame_id: &str) -> Result<i64>;
    pub async fn load_messages_in_epoch(&self, frame_id: &str, epoch: i64) -> Result<Vec<(i64, Message)>>;
    pub async fn load_messages_all_epochs(&self, frame_id: &str) -> Result<Vec<(i64, i64, Message)>>;
    /// 单事务：行从 MAX(seq)+1 起连续分配、写记录、head_epoch += 1。返回新 epoch。
    pub async fn open_context_epoch(&self, frame_id: &str, input: OpenContextEpoch<'_>) -> Result<i64>;
    pub async fn context_epochs(&self, frame_id: &str) -> Result<Vec<ContextEpochRecord>>;
    pub async fn resolve_message_epoch(&self, frame_id: &str, seq: i64) -> Result<Option<i64>>;
}
```

### 测试（`crates/wisp-store/src/store_tests.rs` 或新 `context_epochs_tests.rs`）

- fresh database 含新列、新表、索引；legacy database 重开后幂等补齐，重跑不丢行。
- 旧库所有行 `epoch=0`，`load_messages` 结果与迁移前逐行一致。
- `open_context_epoch`：旧行不变；新行 seq 从 `MAX+1` 连续；`head_epoch` 递增；`load_messages` 只见新纪元；`load_messages_all_epochs` 见全部。
- `append_message` 落到 head 纪元；`max_message_seq` 为 frame 级最大值。
- `replace_messages` 清空纪元记录并重置 `head_epoch=0`。
- `resolve_message_epoch` 对每个 seq 返回唯一 epoch。
- research archive 导出 / 导入多纪元 frame 往返无损；project transfer 拷贝后 `epoch` / `head_epoch` 保留。
- `delegation_runtime` 子帧在有 seq gap 时仍能追加（不再用 `len()+1`）。

### 验证

```bash
cargo test -p wisp-store
cargo test -p wisp-tauri delegation_runtime
cargo fmt --all -- --check
```

## PR 2：压缩开启新纪元

**用户问题：** 压缩不再抹掉旧上下文；`turn_file_undo`、resource links、reviews 不再在压缩时被清空（#973）。

### 修改

- `crates/wisp-core/src/context.rs`：
  - `compact_with_reserve_reference` 返回 `CompactionOutcome { before, after, kind, kept_from_index }`（`kept_from_index` 为保留 tail 首条在压缩前列表中的下标；prune-only 为 `None`）。`compact` / `compact_with_reserve` 同步。
  - `is_summary_checkpoint` 改为 `pub`。
- `crates/wisp-core/src/lib.rs`（`Agent::compact`）与 `agent.rs` 的 auto / overflow / iteration-limit 路径：透传 outcome；`Output::compaction` 签名不变。
- `src-tauri/src/agent_turn.rs`：
  - `/compact`：`open_context_epoch` 替代 `replace_messages`；先落库再发 `Compaction { epoch: Some(n) }`，并把事件的 ui seq 回写 `context_epochs.ui_event_seq`。
  - 轮末 `compaction_revision` 变化分支：`open_context_epoch`（一轮多次压缩只落一个纪元，`strategy` 取最后一次）；`ui_event_seq` 取本轮最后一个 Compaction 画面事件。
  - `first_kept_seq`：在父纪元行中按 `(role, ts, content)` 定位 tail 首条，尽力而为，找不到为 `None`。
  - 轮末不再有任何 `DELETE` 路径。
- `crates/wisp-store/src/sessions.rs`：`replace_message_rows` 里对 `turn_file_undo` 的 wipe 只在「从零建立 epoch 0」语义下保留；压缩路径不经过它。
- `crates/wisp-dto/src/lib.rs`：`AgentEvent::Compaction` 加 `#[serde(default)] epoch: Option<u64>`；`ChatItem::Compaction` 加 `epoch: Option<u64>`。`src-tauri/src/lib.rs` 本地 `AgentEvent` 同步。
- `crates/wisp-cli`：headless 压缩若持久化会话，走同一 Store API；eval 的 `CompactionRecord` 不变。
- 文档：`docs/model-configuration.md` 压缩一节改写「只重写 `messages` 行」为「开启新纪元、旧上下文冻结保留」。

### 接口

```rust
pub struct CompactionOutcome {
    pub before: usize,
    pub after: usize,
    pub kind: CompactionKind,           // PruneOnly | Semantic
    pub kept_from_index: Option<usize>,
}
```

### 测试

- `wisp-core`：outcome 的 `kind` / `kept_from_index` 在 prune-only 与语义两条路径下正确；现有压缩测试全部改用新返回值。
- `src-tauri`（`agent_turn` 测试 + `lib_tests.rs`）：
  - `/compact` 后：epoch 0 行逐行不变；head 纪元 = system + checkpoint + tail；所有旧 `MessageBoundary.seq` 仍能 `resolve_message_epoch`；`turn_file_undo` 行保留。
  - 轮中 auto compact（fake provider 触发）：本轮追加行以旧纪元落库；轮末只开一个纪元；`context_epochs.ui_event_seq` 指向本轮 Compaction 事件。
  - 连续两次压缩形成链 `parent_epoch` 正确。
- `dto_contract_tests.rs`：带 / 不带 `epoch` 的 `Compaction` 事件均可反序列化。
- `store_tests.rs`：`side_chat_snapshot_survives_compaction_and_stops_at_completed_boundary` 改为经 `open_context_epoch`。

### 验证

```bash
cargo test -p wisp-core compact
cargo test -p wisp-tauri compaction
cargo test -p wisp-store
cargo fmt --all -- --check
```

## PR 3：锚点解析、`rewind_to_seq`、回溯 / 分支迁出「index 当 seq」

**用户问题：** 从压缩前的任意气泡回溯或开分支，结果就是那一刻的完整上下文，不再切错或空操作。

### 修改

- `crates/wisp-store/src/sessions.rs`：
  - 新增 `visual_turn_anchor(frame, user_index) -> Option<i64>`：第 N 个 `User` 画面事件之后第一个 `MessageBoundary.seq`。
  - 新增 `rewind_to_seq(frame, epoch, keep_seq)`：`head_epoch = epoch`；删 `context_epochs WHERE epoch > ?`；删 `messages WHERE seq > keep_seq`（frame 级，后续纪元自然被删）；画面按 boundary 截断；`turn_file_undo` / `message_resource_links` / `session_reviews` 按 seq 截断；`project_state_revisions` 按画面轮数截断（沿用现有逻辑）。
  - `truncate_messages(frame, keep)` 改为 `rewind_to_seq(frame, head_epoch, keep)` 的薄封装，并标注 `keep` 是 seq。
  - `reconcile_session_branches_after_truncate`：分支锚点保留判断改用画面 `User` 事件计数 + 对应 boundary 之后是否有 assistant 行，而不是数 head 纪元里的 user 行。
- `src-tauri/src/session_commands.rs`：
  - `rewind_session`：`user_index` → `visual_turn_anchor` → `resolve_message_epoch` → `rewind_to_seq(frame, epoch, anchor_seq - 1)`；无画面锚点（legacy 前缀）时回退到 epoch 0 行的 `user_message_start`。不再在内存中 `truncate`：移除该 frame 的 `SessionRuntime.agent`，下一轮从 store 重建。
  - `branch_session`：同样解析 `(epoch, keep_seq)`，拷贝 `load_messages_in_epoch(epoch)` 中 `seq <= keep_seq` 的前缀；`after_response` 取下一 user 锚点减一，末轮取该纪元末尾。
  - `user_index_to_keep_after_db` 改名或删除。
  - `load_session`：legacy 前缀（首个 boundary 之前的行）从 epoch 0 计算。
- `src-tauri/src/agent_turn.rs`：InterruptReplace 的 `replace_messages` 改为 `rewind_to_seq(frame, head_epoch, turn_start_seq)`，`turn_start_seq` 由 `load_messages_with_seq` 在轮起始记录。
- `src-tauri/src/lib.rs`：`user_message_start` 仅供 legacy 回退使用，加注释。
- 文档：`docs/exploration-branches.md` 中普通分支 / 回溯段落更新。

### 接口

```rust
impl Store {
    pub async fn visual_turn_anchor(&self, frame_id: &str, user_index: usize) -> Result<Option<i64>>;
    pub async fn rewind_to_seq(&self, frame_id: &str, epoch: i64, keep_seq: i64) -> Result<()>;
}
```

### 测试

- Store：
  - 压缩两次后 `rewind_to_seq(epoch 0, S)`：`head_epoch=0`、`epoch>0` 行与记录消失、`seq>S` 行消失、画面截到对应 boundary、undo / links / reviews 一致。
  - 在 head 纪元内回溯与今天 `truncate_messages` 行为一致（现有测试全部通过）。
  - 分支 orphan 语义：`rewinding_past_a_branch_checkpoint_keeps_it_as_frozen_history`、`after_response_checkpoint_requires_the_reply_to_survive_rewind` 在有压缩纪元时仍成立。
  - `visual_turn_anchor` 对 legacy 前缀返回 `None`。
- src-tauri：
  - 压缩后从压缩前气泡 `rewind_session`：模型上下文回到该轮之前的全量前缀；前端 `load_session` 与之一致（不再「先本地 take 再跳回完整画面」）。
  - 压缩后从压缩前气泡 `branch_session(before_user | after_response)`：新 frame 的 `messages` 是正确前缀，且不含 checkpoint。
  - InterruptReplace 在 seq 有 gap 时正确回滚。
  - 已缓存的 in-memory agent 在 rewind 后被丢弃并从 store 重建。

### 验证

```bash
cargo test -p wisp-store rewind
cargo test -p wisp-store branch
cargo test -p wisp-tauri session_commands
cargo test -p wisp-tauri agent_turn
cargo fmt --all -- --check
```

## PR 4：探索走锚点，移除压缩阀

**用户问题：** 「从压缩前的回复开始探索」不再报「上下文已被压缩，无法安全恢复」。

### 修改

- `src-tauri/src/exploration_commands.rs`：
  - 删除 `historical && (visual_turn_count > fallback_turn_count || 含 checkpoint)` 的 `ERR_HISTORY_UNAVAILABLE` 分支。
  - `selected_message_head` / `selected_messages` 由 `visual_turn_anchor` + `resolve_message_epoch` + `load_messages_in_epoch` 得到；legacy 前缀保留现有回退。
  - `ERR_HISTORY_UNAVAILABLE` 仅保留「无稳定完成边界」「越界」「锚点缺失」三种情形。
  - `write_context_archive` 的 `message_head` 语义不变（对应纪元内的 seq）。
- `docs/exploration-branches.md`：更新「压缩 vs 探索」一节。

### 测试

- 压缩两次后从压缩前任意历史轮开探索：clone 的 `messages` 是该轮前缀，且 `latest_native_turn_is_complete`。
- 从 head 纪元最新轮开探索行为不变。
- `rewrite_cloned_context_archive_references`、`replace_exploration_clone_history` 现有测试通过（clone 走 `replace_messages` 建立 epoch 0）。

### 验证

```bash
cargo test -p wisp-tauri exploration
cargo fmt --all -- --check
```

MVP 到此为止：运行全套 `cargo test --workspace`。

## PR 5：撤销压缩 + 可展开的压缩行

**用户问题：** 用户能看见这次压缩留下了什么摘要，不满意可以一键撤销（尚未继续对话时）或回溯到压缩前。

### 修改

- `crates/wisp-store/src/context_epochs.rs`：`undo_context_epoch(frame) -> Result<i64>`：仅当 `MAX(seq) WHERE epoch=head` == `initial_head_seq` 时允许；单事务删 head 纪元行与记录、`head_epoch = parent_epoch`；否则返回带码错误 `context_epoch_has_new_turns`。
- `crates/wisp-dto/src/lib.rs`：
  - `AgentEvent::CompactionUndone { frame_id, epoch }`。
  - `ChatItem::Compaction` 加 `checkpoint: Option<String>`、`kept_from_user_index: Option<usize>`、`undone: bool`。
  - `ContextEpochDto`；`LoadedSessionPage.context_epochs: Vec<ContextEpochDto>`、`head_epoch: u64`。
- `src-tauri/src/session_commands.rs`：
  - 新命令 `undo_compaction(session_id)`：门禁（未归档、非 ACP、非 merged / orphaned 分支、可写 scope、无运行中 turn）→ `undo_context_epoch` → 丢弃 in-memory agent → 追加并发出 `CompactionUndone`。
  - `load_session` 返回 `context_epochs`、`head_epoch`，并把 checkpoint 文本、`kept_from_user_index`（由 `first_kept_seq` 反查画面 user 序号）合并进对应 `Compaction` 行；`CompactionUndone` 事件把对应行标 `undone`。
- `ui/src/chat_render.rs`：压缩行可展开（默认折叠）：checkpoint 全文（Markdown 只读）、`before → after`、strategy、纪元号、「保留自第 k 轮」；动作「撤销压缩」（可用条件由后端字段决定，不可用时显示原因）与「回溯到压缩前」（复用现有 rewind 预览 / 确认流程，目标为 `kept_from_user_index` 之前）。已撤销的行灰化并加删除线样式。
- `ui/src/main.rs`：`undo_compaction` invoke、`CompactionUndone` 事件处理；展开态进入 Escape 栈。
- `ui/src/app_support/messages.rs`：新增 `compose_icon` kind（撤销压缩、展开摘要），与现有集合去重。
- `ui/src/i18n.rs`：En + Zh 文案。
- `ui/src/styles/chat.css`：展开区与 undone 样式。
- 文档：`docs/conversation-history.md` 增加「压缩行、撤销压缩」。

### 接口

```rust
impl Store {
    pub async fn undo_context_epoch(&self, frame_id: &str) -> Result<i64>;
}
#[tauri::command] async fn undo_compaction(session_id: Option<String>) -> Result<u64, String>;
```

### 测试

- Store：无新增行时撤销成功回到父纪元、旧行原样；有新增行时拒绝且无副作用；连续撤销两级。
- src-tauri：命令门禁；撤销后 `load_session` 的 `head_epoch` 与 `Compaction.undone` 正确；in-memory agent 被丢弃。
- `dto_contract_tests.rs`：新字段缺省可反序列化；`CompactionUndone` 往返。
- Leptos 单元：`LoadedItem → ChatItem::Compaction` 合并 checkpoint 文本；undone 标记。
- Playwright（mock bridge）：点击压缩行展开显示摘要；打开后立刻按 Escape 只关闭展开层，其它面板不受影响；「撤销压缩」触发 invoke 并把行标为已撤销；有新轮次时按钮禁用并显示原因。

### 验证

```bash
cargo test -p wisp-store context_epoch
cargo test -p wisp-tauri undo_compaction
cargo test -p wisp-tauri dto_contract
cd ui && cargo check --target wasm32-unknown-unknown && cargo test
cd ../ui-tests && npm ci && npx playwright test
```

## PR 6：透明视图——in-context 标记、模型视角、面板行

**用户问题：** 用户随时知道「模型现在看到的是什么」，哪些历史气泡已经只剩摘要。

### 修改

- `src-tauri/src/session_commands.rs`：新命令 `load_session_context_view(session_id) -> Vec<LoadedItem>`：`load_messages`（head 纪元）经现有 `messages_to_items` 渲染；system 行以 `kind="system"` 折叠返回。
- `crates/wisp-dto/src/lib.rs`：`LoadedItem` 无需新字段；`LoadedSessionPage.in_context_from_user_index: Option<usize>`（head 纪元保留 tail 起点对应的画面 user 序号；无压缩时 `None`）。
- `ui/src/main.rs` / `ui/src/chat_render.rs`：
  - 气泡容器带 `data-in-context="true|false"`；`false` 用弱化样式与 tooltip「不在当前上下文，已由摘要代表」；压缩行作为分段线。
  - 记录顶部 / 上下文面板增加切换「完整记录 | 模型视角」；模型视角为只读渲染，不可 rewind / branch / edit；切换状态在会话切换时重置。
- 上下文用量面板：一行 `纪元 n · system + checkpoint + k 轮 tail`（无压缩时不显示）。
- `ui/src/i18n.rs`、`ui/src/styles/chat.css` 对应。
- 文档：`docs/conversation-history.md` 增「模型视角」；`docs/model-configuration.md` 链接。

### 测试

- src-tauri：`load_session_context_view` 对压缩后 frame 返回 system(折叠)+checkpoint+tail；`in_context_from_user_index` 与 `first_kept_seq` 一致；`first_kept_seq=None` 时返回 `None`。
- Leptos 单元：给定 `in_context_from_user_index`，各气泡 `data-in-context` 判定正确；分页（`user_offset`）下仍正确。
- Playwright：压缩后旧气泡弱化、tail 气泡正常；切换模型视角显示 checkpoint 且右键 / 悬浮动作不可用；切回完整记录恢复；面板行文案正确。

### 验证

```bash
cargo test -p wisp-tauri context_view
cd ui && cargo check --target wasm32-unknown-unknown && cargo test
cd ../ui-tests && npx playwright test
cargo test --workspace
cargo fmt --all -- --check
```

## 手动 smoke（PR 2、3、5、6 后各做一次）

1. 用小 `max_context` 的模型配置开新会话，连续跑十几轮带工具的对话，触发自动压缩；确认画面完整、压缩行出现、`.wisp/history/<id>.json` 生成。
2. 展开压缩行，核对 checkpoint 摘要与「保留自第 k 轮」；切换模型视角核对 head 纪元内容。
3. 在压缩前的某个用户气泡上「编辑并回溯」：确认模型上下文回到该轮之前（下一轮回答只知道那之前的事）、画面截断正确、`turn_file_undo` 可还原压缩前改过的文件。
4. 在压缩前的回复上「分支」与「开始探索」：新会话 / 探索包含到该轮为止的完整上下文，无 checkpoint。
5. 重新压缩后立即「撤销压缩」：上下文回到压缩前；再发一条消息后按钮变为禁用并显示原因。
6. Windows 与 macOS 各跑一次 1–5；确认 `.wisp/history` 路径与 `wisp-history:` 解析未变。

## 已知限制与后续

- 一轮内多次压缩只落一个纪元；撤销粒度为整轮。
- 回溯到冻结纪元会删除被跨过的纪元（与今天 rewind 删除后续行同性质）；reflog 式保留为后续项。
- `first_kept_seq` 尽力而为，只影响 UI 标记，不影响回溯 / 分支正确性。
- 冻结纪元不 GC；存储增长与今天的 `.wisp/history` 同阶。后续可在 frame 归档时清理非 head 纪元。
- `branch_point_user_index` 仍是画面 user 序号；改为 `(epoch, seq)` 锚点是后续项。
- prune 墓碑仍持久化；改为请求构建期计算（OpenCode / Pi 做法）不在本计划内。
- ACP 会话不参与压缩，本计划对其无影响。

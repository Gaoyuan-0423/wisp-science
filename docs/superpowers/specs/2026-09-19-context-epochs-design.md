# 上下文纪元（话中话）设计：可反悔、可透明的上下文压缩

> 对应 Issue：[#1253 /compact 在长工具循环会话上空转，overflow 压缩后仍超窗](https://github.com/xuzhougeng/wisp-science/issues/1253)（评论区「Compact 之后：画面、分支、回溯、探索」一节）
>
> 关联：#973（compact 后 `turn_file_undo` 丢失）、#978
>
> 状态：设计提案；本文不代表已经实现。实施拆分见 [../plans/2026-09-19-context-epochs.md](../plans/2026-09-19-context-epochs.md)。

## 结论

把一次上下文压缩建模为**在同一个 frame 内开启一个新的上下文纪元（ContextEpoch）**，而不是原地重写 `messages` 表：

1. 压缩前的模型上下文行一行不改、一行不删，成为冻结的旧纪元。
2. 压缩后的工作集（system + `[context summary checkpoint]` + 保留 tail）作为**新行**追加，归属新纪元；`frames.head_epoch` 指向它。
3. `seq` 在 frame 内跨纪元单调递增，**永不重编号**。所有按 seq 锚定的记录（`session_ui_events.MessageBoundary`、`turn_file_undo`、`message_resource_links`、`session_reviews`）在压缩后继续有效。
4. 回溯 / 分支 / 探索的目标由画面气泡的 `MessageBoundary.seq` 唯一解析到 `(epoch, seq)`；回到压缩前的某一轮 = 把 `head_epoch` 指回旧纪元并截断，不需要任何「画面序号 ↔ 模型序号」的猜测映射。
5. 撤销压缩 = `head_epoch` 退回父纪元。
6. 压缩后的上下文对用户透明：head 纪元的行就是模型此刻看到的全部内容，UI 可以原样渲染 checkpoint 摘要与保留 tail，并标出哪些画面气泡已不在模型上下文中。

这等价于 Pi 的 append-only session tree（`CompactionEntry.firstKeptEntryId`）和 git「squash 成新 commit、旧 commit 留在 reflog」。它把「新对话 / 话中话」落在 `messages` 层而不是 `frames` 层，`frame_id` 保持稳定。

## 现状与设计依据

今天所有痛点都源自一个函数：

```rust
// crates/wisp-store/src/sessions.rs::replace_message_rows
DELETE FROM message_resource_links WHERE frame_id=?;
DELETE FROM turn_file_undo WHERE frame_id=?;       // #973/#978: seq 全换，只能 wipe
DELETE FROM messages WHERE frame_id=?;
INSERT ... seq = 1..n                               // 重编号
```

由此产生的连锁：

- `session_ui_events` 有意保留全量画面，但其中 `MessageBoundary.seq` 指向的是压缩前的编号，从此与 `messages` 失联。
- `rewind_session` / `branch_session` 用「第 N 个 user」在重编号后的表里数位置（`user_message_start`），语义压缩后 checkpoint 本身是 `role=user`，会数错或落到末尾成为空操作。
- `exploration_commands.rs` 只能 fail-closed（`ERR_HISTORY_UNAVAILABLE`），注释明确写着「compaction 会独立重排模型行号，不能把旧画面 index 映射到更新的模型轮次」。
- `compaction_revision` 仅在内存；`.wisp/history/<id>.json` 是无 seq 的裸 `Vec<Message>`，不会被任何回溯路径读回。
- `turn_file_undo` 在每次 compact 时整帐清空。

数据其实没丢（归档全量在），丢的是**归档与画面 seq 之间的映射**。纪元模型不再需要映射，因为旧行根本没动。

### 为什么不是「压缩 = 新 frame」

字面上的「新对话」也能做到旧对话不动，但 `frame_id` 是全库主锚：30 多张表 `REFERENCES frames(id)`（messages、ui events、undo、reviews、resource links、branch merges、project_state_revisions、exploration family 的 `mainline_frame_id`、research archives、workflows、runs/artifacts……）；`SessionRuntime`、turn queue、事件订阅、UI 过滤全按 frame 键。自动压缩发生在**一轮之中**（`agent.rs` 每次模型请求前检查 `needs_auto_compact_with_reserve`），同一轮前半段事件已以旧 frame 落库并推给 UI，中途换身份要处理跨 frame 的流式渲染、Done、stop_agent、会话列表隐藏和 4 项模型设置复制。收益（旧上下文完整可回溯）在纪元模型里同样拿到，代价小一个量级。

## 术语

- **ContextEpoch（上下文纪元）**：一个 frame 在某个时间点发给模型的完整上下文行集合。epoch 0 是原始对话；每次成功压缩开启 epoch n+1。
- **head 纪元**：`frames.head_epoch`，当前发给模型的那一份。
- **冻结纪元**：`epoch < head_epoch` 的行，只读；只有 rewind 会删除它们。
- **保留 tail**：语义压缩后从原上下文原样拷入新纪元的最近轮次（现有 `RECENT_TAIL_MAX_TURNS` / `RECENT_TAIL_MAX_TOKENS`）。
- **锚点**：画面某个气泡对应的 `MessageBoundary.seq`；解析为 `(epoch, seq)`。

## 数据模型

```sql
-- 幂等 ALTER，旧库默认 0
ALTER TABLE messages ADD COLUMN epoch INTEGER NOT NULL DEFAULT 0;
ALTER TABLE frames   ADD COLUMN head_epoch INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_messages_frame_epoch_seq ON messages(frame_id, epoch, seq);

CREATE TABLE IF NOT EXISTS context_epochs (
    frame_id          TEXT NOT NULL REFERENCES frames(id) ON DELETE CASCADE,
    epoch             INTEGER NOT NULL,
    parent_epoch      INTEGER NOT NULL,
    strategy          TEXT NOT NULL,            -- manual | auto | overflow
    kind              TEXT NOT NULL,            -- prune_only | semantic
    before_tokens     INTEGER NOT NULL,
    after_tokens      INTEGER NOT NULL,
    first_seq         INTEGER NOT NULL,         -- 该纪元第一行（system）
    initial_head_seq  INTEGER NOT NULL,         -- 开启时最后一行；> 它的行是压缩后新增
    checkpoint_seq    INTEGER,                  -- checkpoint 行；prune_only 为 NULL
    first_kept_seq    INTEGER,                  -- 保留 tail 首条在父纪元中的 seq（尽力而为）
    archive_ref       TEXT,                     -- wisp-history:<id>
    ui_event_seq      INTEGER,                  -- 对应 Compaction 画面事件
    created_at        INTEGER NOT NULL,
    PRIMARY KEY(frame_id, epoch)
);
```

`UNIQUE(frame_id, seq)` 保持不变。新纪元的行从 `MAX(seq)+1` 起连续分配；`SessionRuntime::sync_last_seq_from_store` 继续用 frame 级 `MAX(seq)`，与纪元无关。

epoch 0 不写 `context_epochs` 记录（隐含）。

## 不变量

1. 冻结纪元的行不被压缩 UPDATE / DELETE。只有用户显式 rewind 会删。
2. `(frame_id, seq)` 唯一解析到一行；该行的 `epoch` 即锚点所在纪元。画面 `MessageBoundary.seq` 永远可解析。
3. `Store::load_messages(frame)` 只返回 head 纪元；这是所有「模型上下文」读者的唯一入口。
4. 每次**成功**压缩（无论 prune-only 还是语义）都开启一个新纪元。统一路径，不区分「原地改内容」与「整表替换」。存储代价与今天每次压缩全量写 `.wisp/history/<id>.json` 同阶。
5. archive-first 不变：先写 `.wisp/history/<id>.json`，`context_epochs.archive_ref` 记录引用；模型侧 `wisp-history:` 解析规则不变。DB 里的冻结纪元才是回溯真源，文件是模型可 `read`/`grep` 的导出。
6. `replace_messages` 只保留给「从零建立 epoch 0」的场景（导入、seed、exploration clone）；它重置 `head_epoch=0` 并删除全部纪元记录。压缩路径不再调用它。

## 四条操作语义

| 操作 | 现在 | 纪元模型 |
| --- | --- | --- |
| 读模型上下文 | 全表 | `epoch = head_epoch` 的行，按 seq |
| 压缩 | `DELETE` + 1..n 重写 | 旧纪元不动；把压缩后的列表作为新行追加到 `MAX(seq)+1…`，写 `context_epochs`，`head_epoch += 1` |
| 回溯到某气泡 | 数「第 N 个 user」 | 锚点 `(e, S)`。`e == head`：删 `seq > S`。`e < head`：`head_epoch = e`，删所有 `seq > S`（后续纪元的 seq 必然更大，自然一并删除），画面按 boundary 截断，undo/links/reviews 按 seq 截断 |
| 从某气泡分支 / 探索 | 切错前缀或 `ERR_HISTORY_UNAVAILABLE` | 锚点 `(e, S)` → 拷 `epoch=e AND seq<=S` 前缀到新 frame（新 frame 从 epoch 0 重新编号） |

补充：

- **撤销压缩**：仅当 head 纪元没有新增行（`MAX(seq) WHERE epoch=head` == `initial_head_seq`）时允许，`head_epoch = parent_epoch`，删 head 纪元行与记录，追加 `CompactionUndone` 画面事件。有新增行时 UI 改为提供「回溯到压缩前」。
- **轮中自动压缩**：内存 ctx 立即变小（同今天）；DB 侧本轮新增行继续以旧纪元、递增 seq 追加，boundary 有效。轮末在今天调用 `replace_messages` 的位置改为「开启新纪元」，把内存中的完整 ctx 作为新纪元写入。一轮多次压缩只落一个纪元。崩溃在轮末之前：DB 仍是自洽的旧纪元（未压缩），下次启动再压，行为与今天一致。
- **手动 `/compact`**：不在模型轮中，立即开启纪元，Compaction 事件携带 epoch。
- **锚点解析**：后端由画面 user 序号在 `session_ui_events` 中找第 N 个 `User` 事件之后的第一个 `MessageBoundary` 得到 seq（纯画面侧，与纪元无关）；旧库中「UI 事件持久化之前」的前缀轮次保留今天按 epoch 0 行计数的回退。
- **回溯后的内存代理**：不再在内存中 `truncate`；直接丢弃该 frame 的 `SessionRuntime.agent`，下一轮从 store 重建（`agent_turn.rs` 已有该路径）。
- **回到冻结纪元后的 token 反弹**：下一轮几乎必然再触发自动压缩并开启新纪元（父纪元 = 被恢复的那个）。这是期望行为（换一个 tail 重新摘要）；需确认 `auto_compact_retry_floor` 不会把它压掉。
- **rewind 的破坏性**：删除被跨过的纪元与今天 rewind 删除后续行同样是显式、需确认的破坏性动作；把被跨过的纪元保留为「reflog」不在本轮范围。

## 透明性（用户能看到模型看到了什么）

- `ChatItem::Compaction` 可展开：显示 checkpoint 摘要全文（就是 head 纪元那条 `[context summary checkpoint]` user 行）、保留 tail 从画面第几轮开始、`before → after`、strategy、epoch 号，以及「撤销压缩」/「回溯到压缩前」动作。
- 画面气泡带 `data-in-context`：不在 head 纪元（`seq < first_kept_seq` 或属冻结纪元）的气泡以弱化样式标出「不在当前上下文」；压缩行充当分段线。
- 「模型视角」切换：把 head 纪元的行经现有 `messages_to_items` 渲染为只读记录，替代画面记录展示；system 折叠、checkpoint 完整、tail 原样。复用现有渲染，不新造面板。
- 上下文用量面板增加一行：`纪元 n · system + checkpoint + k 轮 tail`。

## 影响面

### wisp-core

`compact_with_reserve_reference` 已持有 `original_messages` 与 recent tail；只需把返回值扩为 `CompactionOutcome { before, after, kind, kept_from_index: Option<usize> }`，并把 `is_summary_checkpoint` 暴露为 pub。`ContextManager` 不感知纪元。CLI 头 less 路径走同一个 store API。

### wisp-store

新增 `context_epochs` 表、`messages.epoch`、`frames.head_epoch` 与对应 Store API；`truncate_messages(frame, keep)` 泛化为 `rewind_to_seq(frame, epoch, keep_seq)`。`reconcile_session_branches_after_truncate` 改为用画面 `User` 事件计数判断分支锚点是否保留（`truncate_message_rows` 已对 `project_state_revisions` 这样做）。

### src-tauri

- `agent_turn.rs`：`/compact` 与轮末压缩持久化改为开启纪元；InterruptReplace 的 `replace_messages` 改为按 seq 截断（同 rewind）。
- `session_commands.rs`：`rewind_session` / `branch_session` / `user_index_to_keep_after_db` 改为锚点解析；`load_session` 的 legacy 前缀从 epoch 0 计算，并返回 `context_epochs`。
- `exploration_commands.rs`：移除 `ERR_HISTORY_UNAVAILABLE` 的压缩阀，改为锚点解析。
- `load_messages` 调用方审计（见计划 PR 1）。

### wisp-dto / ui

`ContextEpochDto`、`AgentEvent::Compaction.epoch`、`AgentEvent::CompactionUndone`、`ChatItem::Compaction` 扩展、`SessionPage.context_epochs`；UI 展开行、in-context 标记、模型视角、撤销/回溯动作、面板行。所有新弹层进入 window 级 Escape 栈；图标走 `compose_icon()`。

## 非目标

- 不把 prune 墓碑改为请求构建期计算（OpenCode/Pi 做法）；本轮维持持久化墓碑。
- 不做「压缩后不同 tail 的多个候选」或 reflog 式保留被跨过的纪元。
- 不做归档 GC；冻结纪元随 frame 存活。存储增长与今天的 `.wisp/history` 同阶，后续如需可按 frame 归档时清理。
- 不改 `.wisp/history/<id>.json` 的格式或 `wisp-history:` 解析。
- 不改 #1253 正文的三刀（压缩目标、`max_tokens` 预算、参数折叠）；那是独立修复，本设计消除的是评论区提出的「语义摘要之后分支 / 回溯会带崩」的前提。

## 风险

- `keep`-as-index 假设：`rewind_session` 目前把内存 index 直接当 seq 传给 `truncate_messages`，依赖「无 gap、从 1 起」；纪元行从 `MAX+1` 起，这个假设必须在同一 PR 内消除。`delegation_runtime.rs` 用 `load_messages().len()+1` 作为下一 seq，同类问题。
- 一轮内多次压缩只落一个纪元：撤销粒度是「这一轮的全部压缩」。可接受，写进文案。
- `first_kept_seq` 是尽力而为（按 `(role, ts, content)` 在父纪元定位 tail 首条）；它只服务 UI 标记，回溯 / 分支不依赖它。
- 项目迁移 / 研究归档若按列名拷贝 `messages`，需带上 `epoch`；导出类调用方需明确是导出 head 还是全部纪元。

# Tao 升级评估（2026-09-16）

Windows 修复采用 **Tao 0.37.0 + 最小范围的 runtime 接入**。
主工程已通过根目录 Cargo patch 接入 `vendor/tauri-runtime-wry`，其源码来自
正式发布的 2.11.4，只将 Tao 约束从 `0.35.0` 改为 `0.37.0`。
来源、许可证和退出条件见 [WISP-PATCH.md](../vendor/tauri-runtime-wry/WISP-PATCH.md)。
macOS #1250 仍需独立修复，不能把这次升级视为两个问题都已解决。

## 两个问题的覆盖情况

| 问题 | 当前证据 | Tao 0.37.0 的覆盖 |
| --- | --- | --- |
| [#1265](https://github.com/xuzhougeng/wisp-science/issues/1265)：Windows 键盘消息重入死锁 | 旧版 0.35.3 稳定复现，debug dump 明确等待键盘 builder 锁 | 包含上游修复；同一复现程序在隔离项目和主工程中均通过 |
| [#1250](https://github.com/xuzhougeng/wisp-science/issues/1250)：macOS 保存面板引起 redraw 重入 | 用户 spindump 证明主线程自锁；具体 Tao 路径依据源码和调用结构定位，原 EXE 缺少 dSYM | 仍未覆盖；0.37.0 和当前 dev 的 `handle_redraw` 仍直接调用持有 callback mutex 的路径 |

#1250 当前为 closed，但其回复本身说明尚未修复。升级不能改变这个交付状态；
需要独立的防重入/延迟重绘方案，以及 macOS 实机上的保存、打开、目录选择等
原生面板验证。此 Windows 机器没有提供这项 macOS 实机证据。

## 当前发布链与接入约束

修复前主工程锁定：

```text
tauri 2.11.3
  tauri-runtime-wry 2.11.4
    tao ^0.35.0 -> 0.35.3
    wry ^0.55.0 -> 0.55.1
```

修复后仍为 Tauri 2.11.3 / runtime-wry 2.11.4 / Wry 0.55.1；只有 Tao
变为 0.37.0、tao-macros 变为 0.1.4，以及 Tao 引入的 Windows 0.62 等传递依赖。
已有 Windows 0.61 依赖保留，runtime 的 Rust 源码没有适配修改。

本次实时查询 crates.io：最新稳定 Tauri 为 2.11.5，runtime-wry 仍为 2.11.4，
Tao 为 0.37.0，Wry 为 0.57.0。已发布 runtime 仍限制 Tao `^0.35.0`。
因此单独 `cargo update`、升级 Tauri 到 2.11.5，或新增一个直接 Tao 0.37
依赖，都不会把 runtime 实际使用的 Tao 自动换为 0.37。

Tauri dev 已接入 Tao 0.37 / Wry 0.56，但这不是当前正式发布组合。完整采用
开发分支会带入与本问题无关的修改。更小的接入边界是固定一份
`tauri-runtime-wry 2.11.4` 源码副本，仅提高 Tao 约束，再用锁文件固定结果；
待正式 runtime 发布兼容版本后移除该覆盖。不能把 Tao 0.37 伪装成 0.35.3。

## 实际隔离验证

在 `test-results/tao-upgrade-assessment/probe-037/` 建立独立 Cargo workspace：

- 保留 Tauri **2.11.3**、tauri-runtime **2.11.3** 和 Wry **0.55.1**。
- 使用 runtime-wry **2.11.4** 的本地副本，将其 Tao 约束从 `0.35.0` 改为 `0.37.0`。
- 将该临时锁文件的 `tao-macros` 从 **0.1.3** 更新到 **0.1.4**。
- 复制原生复现程序，核对 SHA-256 与原文件完全一致。
- Windows x86_64 编译成功，**runtime Rust 源码没有做适配修改**。

| 场景 | 当前 Tao 0.35.3 | 隔离 Tao 0.37.0 |
| --- | --- | --- |
| keydown + sent focus 重入 | 5/5 卡住 | 5/5 返回正常 |
| keyup + sent focus 重入 | 3/3 卡住 | 5/5 返回正常 |
| 普通 char / syschar + pending focus | 各 3/3 返回正常 | 各 5/5 返回正常 |
| 串行输入与焦点对照 | 5 轮、20 个消息全部正常 | 5 轮、20 个消息全部正常 |

0.37 共通过 40 个消息场景。实验只创建隔离的隐藏原生窗口，没有创建 WebView、
运行完整 Wisp、加载用户数据库或接触真实输入法。证明的是 Windows 原生接入
可编译和已知死锁回归通过，并非整个产品的发布验收。

## 主工程 Windows 验证

接入主工程后在报告机器上再次验证，以下不是隔离 probe 的重复引用：

| 检查 | 结果 |
| --- | --- |
| `cargo tree --locked -p wisp-tauri -i tao` | runtime 实际使用 Tao 0.37.0，无旧版 Tao 并存 |
| 完整 `wisp-tauri` 桌面二进制及三个原生 example 编译 | 通过 |
| 五次独立重入进程 + 五次串行对照 | 40/40 个消息场景通过；每个进程 exit 0 |
| 真实 `webview_recovery_smoke` | 重载、renderer 阻塞期间原生 scoped Stop、兄弟窗口保留全部通过 |
| 真实 `mcp_app_isolation_smoke` | 子 renderer 阻塞时主界面 DOM 可操作；关闭、清理及五次创建/销毁通过 |
| `cargo fmt --all -- --check` 与 UI wasm `cargo check --locked` | 通过 |
| `webview-health` / `long-session-stress` Playwright | 5/5 通过 |
| vendor 来源核对 | 所有 Rust 源码、build.rs、原清单和许可证与发布 crate 相同；活动清单只改 Tao 约束 |

两个真实 WebView smoke 在退出时均打印 Chromium `Failed to unregister class
Chrome_WidgetWin_0 (1412)`；程序均正常 exit 0，功能断言已通过。该退出诊断与
原先主线程输入死锁的证据不同，保留日志供后续检查，不把整个运行称为无错误日志。

本轮原始测试产物位于 `test-results/windows-tao-fix/`，不提交到仓库。
真实中文 IME、Snap/托盘/宠物操作、五小时以上运行以及 macOS/Linux 实机行为
仍需要后续验收。

## 升级收益与风险

0.35.3 到 0.37.0 跨越 40 个上游提交、44 个文件。除 #1265 对应的
[tao#1215](https://github.com/tauri-apps/tao/pull/1215) 外，值得接入的修复包括：

- [tao#1264](https://github.com/tauri-apps/tao/pull/1264)：Windows 任务栏事件的锁重入。
- [tao#1252](https://github.com/tauri-apps/tao/pull/1252)：Windows DPI 查询泄漏 HDC。
- [tao#1271](https://github.com/tauri-apps/tao/pull/1271)：事件投递可能延迟到下次投递才被处理。
- Windows 无边框窗口闪烁、隐藏窗口最大化等行为修复，以及 macOS 标题栏按钮位置修复。

主要回归面：

- Windows 移除了旧窗口 subclassing，并同步了一批 winit 键盘实现。
- IME 文本改由 `ImmGetCompositionStringW` 提取，需要验证中文组合输入、候选确认、
  Escape、快捷键及焦点切换。
- 窗口生命周期变化需要覆盖 Wisp 自定义标题栏/Snap、宠物的透明置顶窗口、
  托盘恢复、MCP 子 WebView、主窗口隐藏/重开及多窗口切换。
- Tao 使用 windows/windows-core 0.62；当前 runtime/Wisp 的 0.61 仍并存。
  本机编译证明这个隔离组合可行，不能据此略过窗口行为验证。
- MSRV 提高到 1.85，低于 Wisp 声明的 1.88；Windows 7 支持被移除。
- Linux 的窗口装饰/线程安全也有修改，需要 Linux 编译与基础窗口冒烟。

因此：接入代码成本较小，行为验证成本中等；macOS #1250 仍是独立的实现与
实机验证工作。升级 Wry 0.56/0.57 不应成为修复本次 Windows 死锁的前置条件，
除非完整 Wisp 验证或后续正式 runtime 兼容要求提供新的理由。

## 验证与后续工作

1. 已在独立分支接入 Tao 0.37，保持 Tauri/Wry 其余版本稳定，并记录 runtime 覆盖的来源和退出条件。
2. 已将 #1265 复现程序加入 Windows CI：编译完整 desktop，五轮重入加五轮串行对照，共 40 个消息场景。
3. 为 #1250 单独增加 macOS 重绘防重入方案和 native sheet 回归，获取实机证据；步骤见 [macOS 交接说明](macos-modal-redraw-handoff.md)。该项不能靠 Windows/Playwright 结果代替。
4. 完成 Windows/macOS 窗口功能检查、Linux 冒烟，以及至少覆盖此前报告时长的交互/空闲运行观察，再决定发布。

曾评估将 tao#1215 固定到 0.35.x 上游提交的较窄方案；当前选择 0.37，
同时获得任务栏重入、HDC 泄漏和事件投递修复。后续正式 runtime 支持新版 Tao 后，
应移除临时覆盖。

## 核验来源与产物

- [Tao 0.37 CHANGELOG](https://github.com/tauri-apps/tao/blob/tao-v0.37.0/CHANGELOG.md)
- [Tao 0.37 macOS app_state.rs](https://github.com/tauri-apps/tao/blob/tao-v0.37.0/src/platform_impl/macos/app_state.rs#L366)
- [Tauri 正式版 runtime 清单](https://github.com/tauri-apps/tauri/blob/tauri-v2.11.5/crates/tauri-runtime-wry/Cargo.toml)
- [Tauri dev 接入状态](https://github.com/tauri-apps/tauri/blob/bca4ca58da02f182ef00ef1165e40e400a3cd8dd/crates/tauri-runtime-wry/Cargo.toml)
- [Tauri 更新 Tao 0.36/Wry 0.56 的上游提交](https://github.com/tauri-apps/tauri/commit/7cc68e74ff6981f5c50a52a67d56c5eb2d227188)
- 本机 `test-results/tao-upgrade-assessment/probe-037-build.txt`、`probe-037-results.json` 和逐轮日志。

Tao dev 核验提交为 `27fe28c73ace307eb0b1d1abf457508410f1340e`；其 macOS
`app_state.rs` 与 0.37.0 获取的文件哈希相同。本次接入不替换用户安装的应用，
不代表 macOS/Linux 实机验证或长时间运行验收已完成。

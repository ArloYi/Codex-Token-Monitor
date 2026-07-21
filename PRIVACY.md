# Privacy

[English](#english) | [简体中文](#简体中文)

## English

Codex Token Monitor runs locally on macOS. It does not include analytics, advertising, telemetry, crash-reporting SDKs, or its own networking client.

### Data it reads

The app reads the following local Codex data to calculate and display quota and Token usage:

- `~/.codex/.codex-global-state.json`
- `~/.codex/state_5.sqlite`
- `~/.codex/session_index.jsonl`
- rollout files referenced by the local Codex database
- quota and lifetime usage returned by the Codex-provided `app-server`
- the visible current-task title in the Codex header, when the user grants macOS Accessibility permission

This data can contain project names, local project paths, thread metadata, timestamps, and Token counts. The monitor uses those values in memory to calculate the HUD text. It does not copy them into the repository or send them to a service operated by this project.

### Data it stores

The app stores only:

- HUD position
- HUD scale
- HUD edge-docking state
- the last available lifetime Token value

These values are stored in macOS user defaults. The app does not persist project paths, rollout contents, account credentials, prompts, or responses.

The optional Accessibility permission is used only to locate and read the visible current-task title in the Codex window. The monitor does not record keystrokes, click controls, or persist the accessibility tree.

### Codex communication

The monitor starts the Codex-provided `app-server` on the local machine and communicates with it through standard input and output. The monitor does not control or intercept communication performed by Codex itself. Codex and OpenAI terms and privacy practices continue to apply to Codex.

### System changes

The app does not install a login item, launch agent, notification service, browser extension, analytics SDK, or background updater. It does not modify the Codex application or files under `~/.codex`.

## 简体中文

Codex Token Monitor 在 macOS 本机运行，不包含分析、广告、遥测、崩溃报告 SDK 或自身的网络请求客户端。

### 读取的数据

应用会读取以下本机 Codex 数据，用于计算并显示额度和 Token 用量：

- `~/.codex/.codex-global-state.json`
- `~/.codex/state_5.sqlite`
- `~/.codex/session_index.jsonl`
- 本机 Codex 数据库引用的 rollout 文件
- Codex 提供的本机 `app-server` 返回的额度和历史 Token 用量
- 用户授予 macOS 辅助功能权限后，Codex 顶部当前可见的任务名称

这些数据可能包含项目名称、本机项目路径、任务元数据、时间戳和 Token 数量。监视器只在内存中使用这些值计算浮窗文案，不会把它们复制进项目仓库，也不会发送到本项目运营的服务。

### 保存的数据

应用只保存：

- 浮窗位置
- 浮窗缩放比例
- 浮窗边缘吸附状态
- 最近一次可用的历史 Token 总量

这些值保存在 macOS 用户默认设置中。应用不会持久化项目路径、rollout 内容、账号凭据、提示词或回复内容。

可选的辅助功能权限仅用于定位并读取 Codex 窗口顶部当前可见的任务名称。监视器不会记录键盘输入、点击 Codex 控件或持久化辅助功能树。

### Codex 通信

监视器会在本机启动 Codex 提供的 `app-server`，并通过标准输入输出与其通信。监视器不会控制或拦截 Codex 自身产生的通信。Codex 和 OpenAI 适用的条款与隐私规则仍然有效。

### 系统改动

应用不会安装登录项、启动代理、通知服务、浏览器扩展、分析 SDK 或后台更新程序，也不会修改 Codex 应用或 `~/.codex` 下的文件。

## Author and project status

Created and maintained by [Arlo Yi](https://github.com/ArloYi).

Codex is a trademark of OpenAI. This is an independent community project. It is not affiliated with, endorsed by, or sponsored by OpenAI.

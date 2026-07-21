# Security Policy

[English](#english) | [简体中文](#简体中文)

## English

### Supported version

Only the latest source and release are supported.

Security reports are handled on a best-effort basis. This policy does not create a warranty, service-level commitment, support obligation, or guarantee that every report will receive a fix. Use of the software remains subject to the [license](LICENSE) and [disclaimer](DISCLAIMER.md).

### Report a vulnerability

Use GitHub's private vulnerability reporting option under the repository's Security tab. Do not include Tokens, cookies, account details, complete `~/.codex` files, databases, prompts, responses, or raw logs in a public Issue.

If private vulnerability reporting is unavailable, open a public Issue containing only the affected version, reproduction outline, and risk category. Do not include sensitive evidence. The maintainer will arrange a private follow-up.

### Data boundary

- Quota is requested from the Codex-provided local `app-server`.
- Project and Token totals are read from local `~/.codex` state, `session_index.jsonl`, SQLite, and referenced rollout files.
- With macOS Accessibility permission, the monitor reads only the current task title visible in the Codex header.
- The monitor does not upload this data.
- The monitor does not modify Codex, install a launch agent, or add itself as a login item.

## 简体中文

### 支持版本

仅支持最新源码和最新发布版本。

安全问题按维护者实际能力尽力处理。本说明不构成任何担保、服务等级承诺、持续支持义务，也不保证每个报告都会获得修复。软件使用仍受[许可证](LICENSE)与[免责声明](DISCLAIMER.md)约束。

### 报告安全问题

请通过仓库 Security 页面中的私密漏洞报告入口提交。不要在公开 Issue 中粘贴 Token、Cookie、账号信息、完整的 `~/.codex` 文件、数据库、提示词、回复内容或原始日志。

如果私密漏洞报告入口暂时不可用，可以创建一个不含敏感证据的公开 Issue，只说明受影响版本、复现概要和风险类型，维护者会安排私下跟进。

### 数据边界

- 额度通过 Codex 提供的本机 `app-server` 获取。
- 项目和 Token 数据来自本机 `~/.codex` 状态、`session_index.jsonl`、SQLite 数据库和数据库引用的 rollout 文件。
- 获得 macOS 辅助功能权限后，监视器只读取 Codex 顶部当前可见的任务名称。
- 监视器不会上传这些数据。
- 监视器不会修改 Codex、安装启动代理或自动加入登录项。

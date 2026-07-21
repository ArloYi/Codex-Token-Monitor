# Codex Token Monitor

[English](README.md) | [简体中文](README.zh-CN.md)

> [!IMPORTANT]
> This repository is source-available and does not permit unauthorized commercial use. Personal, research, educational, charitable, and other qualifying noncommercial uses are covered by the [PolyForm Noncommercial License 1.0.0](LICENSE). Commercial use requires prior written permission from the copyright holder.

> [!WARNING]
> The software is provided as is. You assume the risks of installation, permission changes, inaccurate data, service interruption, and account impact. Displayed values are not an official OpenAI bill or quota guarantee. See the [disclaimer](DISCLAIMER.md).

> A dark circular quota gauge for macOS; hover to reveal project details below it.

![Codex Token Monitor preview](docs/assets/quota-hud-preview.svg)

`Default: 60% remaining ring | 40% used / 100% | progress bar`<br>
`Hover downward: Current project / All projects / Lifetime usage`

Codex Token Monitor requires macOS 13 or later and the Codex desktop app installed and signed in. Release builds are Universal 2 and support both Apple silicon and Intel Macs.

## What it shows

- A circular remaining-quota gauge, used percentage, and progress bar are always visible.
- Tokens used by the selected project during the current week.
- Total Tokens used by all local projects during the current week.
- The selected project's share of weekly Token usage.
- Lifetime Token usage when Codex provides it, with a local fallback.
- Project name and usage update within five seconds after you switch tasks or projects in Codex. On first launch, macOS may ask for Accessibility permission so the monitor can read the current task title shown in the Codex header.
- Hover anywhere over the HUD to reveal details; move away to collapse.
- The quota gauge stays in place while the detail rows expand downward.
- The default size is 82% of the reference design. Drag the bottom-right grip while expanded to resize the whole HUD proportionally from 65% to 125%.
- Drag the HUD to any screen edge to collapse it into a circular quota ball. Drag the ball back into the screen to restore the full card.
- A truly transparent rounded window and semantic colors stay clean in light and dark appearances.

The HUD appears only while Codex is the frontmost app. Its main surface passes clicks through to Codex, and it does not use the menu bar or activate itself.

## Download

Download the latest Universal 2 ZIP and checksum from [GitHub Releases](https://github.com/ArloYi/Codex-Token-Monitor/releases/latest). Extract the archive, move the app to Applications if desired, and open it.

The app uses a local ad-hoc signature and is not notarized by Apple. On first launch, macOS may ask you to confirm the app under System Settings > Privacy & Security.

## Build from source

```bash
git clone https://github.com/ArloYi/Codex-Token-Monitor.git
cd Codex-Token-Monitor
zsh ./scripts/test.sh
open "build/Codex Quota HUD.app"
```

Requirements:

- macOS 13 or later
- Xcode Command Line Tools
- Codex desktop app
- Homebrew and `ripgrep` for the test suite
- The system `sqlite3`, `codesign`, and `zip` tools

Install the test dependency with:

```bash
brew install ripgrep
```

To create a distributable ZIP:

```bash
zsh ./scripts/package-release.sh
```

The Universal 2 archive and its SHA-256 checksum are written to `dist/`. Build artifacts and release archives are excluded from Git.

## Use

```text
Default: [ drag | remaining ring | used ratio | progress ]
Hover:   [ drag | quota gauge ]
         [ current project ]
         [ all projects ]
         [ lifetime usage | resize grip ]
Edge:   ( quota % ball )
```

1. Open Codex.
2. Launch `Codex Quota HUD.app`.
3. If macOS requests Accessibility permission, allow it for **Codex 额度**. The permission is used only to read the current task title shown in the Codex header.
4. Select a project in Codex and wait up to five seconds.
5. Hover over the HUD to reveal the project name, weekly usage, weekly total, share, and lifetime total.
6. Drag the HUD to a screen edge and release to collapse it into a status ball. Drag the ball away from the edge to restore it.
7. Switch to another app, such as Chrome, Slack, or WeChat. The HUD hides immediately.

## Data definitions

| Metric | Meaning | Source |
|---|---|---|
| Quota remaining | Remaining percentage in the current quota window | Local Codex `app-server` |
| Project weekly usage | Tokens used by the selected project during the quota window | Local Codex state and SQLite data |
| Weekly total | Tokens used by all local projects during the quota window | Local Codex SQLite and rollout data |
| Project share | Project weekly usage divided by weekly total | Calculated locally |
| Lifetime usage | Account lifetime total, with cached or local fallback | Local Codex `app-server` and local state |

The app prefers the quota window returned by Codex. If it is unavailable, it uses the most recent seven days. With Accessibility permission, project selection reads only the visible current-task title from the Codex header, matches it to local Codex task metadata, and maps its working directory to the containing project. If that signal or permission is unavailable, it falls back to the most recently active local task, then to `selected-project` and `active-workspace-roots`.

## Privacy

Codex Token Monitor reads only the local Codex data required to calculate and display usage:

- `~/.codex/.codex-global-state.json`
- `~/.codex/state_5.sqlite`
- `~/.codex/session_index.jsonl`
- rollout files referenced by the local Codex database
- quota and lifetime usage returned by the local Codex `app-server`
- the visible current-task title in the Codex window, when Accessibility permission is granted

The monitor contains no networking client and does not upload project paths, Codex state, rollout content, or usage statistics. It starts the Codex-provided `app-server` locally and communicates with it over standard input and output. Any communication performed by Codex itself remains subject to the terms and privacy practices that apply to Codex and OpenAI.

The app stores only the HUD position, scale, edge-docking state, and the last available lifetime Token value in macOS user defaults. It does not install a login item, launch agent, notification service, analytics SDK, or crash-reporting SDK.

See [Privacy](PRIVACY.md), [Security](SECURITY.md), and the [disclaimer](DISCLAIMER.md) for the complete data boundary, reporting guidance, and terms of use.

## Project structure

```text
.
├── App/                    # macOS app metadata
├── Sources/                # Native Objective-C implementation
├── docs/                   # PRD and interface assets
├── scripts/                # Build, test, privacy scan, and packaging
├── .github/                # CI, issue templates, and PR template
├── CONTRIBUTING.md
├── DISCLAIMER.md
├── PRIVACY.md
├── SECURITY.md
└── LICENSE
```

## Verification

```bash
zsh ./scripts/test.sh
```

The test suite checks Token formatting, project selection, adaptive text sizing, focus safety, menu-bar removal, app signing, package metadata, and repository privacy rules.

## Known limitations

- macOS 13 or later on Apple silicon or Intel.
- The app depends on Codex's current local state and `app-server` response structure.
- Project totals are derived from locally available Codex history and are not an official billing statement.
- Automatic updates, Apple notarization, and launch at login are not included.

## Documentation

- [Product requirements](docs/PRD.md)
- [Privacy](PRIVACY.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Disclaimer and terms of use](DISCLAIMER.md)
- [Changelog](CHANGELOG.md)

## License and liability

This project uses the [PolyForm Noncommercial License 1.0.0](LICENSE). It permits personal study, research, testing, education, charitable work, and other qualifying noncommercial uses. Commercial use, paid distribution, bundling with a paid product or service, or use for an organization's commercial benefit requires prior written permission from the copyright holder.

The software comes without warranties. You assume the risks and consequences of using, modifying, or distributing it. The [license](LICENSE) and [disclaimer](DISCLAIMER.md) contain the complete terms.

## Author and project status

Created and maintained by [Arlo Yi](https://github.com/ArloYi).

Codex and OpenAI are trademarks or registered trademarks of their respective owners. This is an independent community project. It is not affiliated with, endorsed by, sponsored by, or officially supported by OpenAI.

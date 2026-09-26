# Codex Token Monitor for Windows

Windows 10/11 portable edition. Open Codex and sign in, then double-click `Start.cmd`.
Uses built-in Windows PowerShell 5.1 and .NET Framework; no administrator access or extra runtime is required. Script execution policy is bypassed only for this launch process, not changed on the machine. Organization-enforced policies still apply.

The HUD appears while Codex is foreground. Hover for details, drag to move, drag to a screen edge for a circular quota ball. Right-click the HUD to refresh or exit.

Quota comes from the local Codex app-server. Token totals come from local session rollouts. The project shown is the most recently active local project, not the selected task in the desktop UI. Remote/WSL sessions are not included unless their data and matching Codex executable are available in the configured home.

If detection fails, set `CODEX_BINARY` to the full path of the native `codex.exe`. `CODEX_HOME` defaults to `%USERPROFILE%\.codex`. The monitor never reads or copies login credentials. Position is saved under `%LOCALAPPDATA%\CodexTokenMonitor\position.txt`.

For protocol checks, run `powershell -NoProfile -File .\CodexQuotaHUD.ps1 -SelfTest`.

License: MIT. See the root README, PRIVACY.md and DISCLAIMER.md for data boundaries and terms.

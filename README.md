# PraestoClaw Installer

Public mirror of the PraestoClaw install scripts, Teams app package,
and Python distribution.

## Install
```powershell
# Windows
irm https://aka.ms/praestoclaw/install.ps1 | iex
```
```bash
# macOS / Linux
curl -fsSL https://aka.ms/praestoclaw/install.sh | bash
```

## Artifacts
- [install.ps1](install.ps1) — Windows installer
- [install.sh](install.sh) — macOS / Linux installer
- [update.ps1](update.ps1) — Windows updater
- [update.sh](update.sh) — macOS / Linux updater
- [PraestoClaw-teams-app.zip](PraestoClaw-teams-app.zip) — Teams sideload package
- [latest.txt](latest.txt) — current published version
- `dist/` — version-pinned wheel and sdist archives

Generated manually from gim-home/PraestoClaw commit 7de2dd9617820b497d543ffeef9033d2a6bbe8ca with package version 1.1.5.

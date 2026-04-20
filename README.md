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
- [PraestoClaw-teams-app.zip](PraestoClaw-teams-app.zip) — Teams sideload package
- [latest.txt](latest.txt) — current published version
- `dist/` — version-pinned wheel and sdist archives

Generated automatically from the private
[gim-home/PraestoClaw](https://github.com/gim-home/PraestoClaw)
repository — **do not edit files here directly**, they will be
overwritten on the next sync.

Landing site: https://gim-home.github.io/PraestoClaw/

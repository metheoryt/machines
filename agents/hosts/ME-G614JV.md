# Host: ME-G614JV

<!--
Per-host memory + instructions for this machine (ASUS, Windows 11 / Git Bash).
Symlinked to ~/.claude/host-memory.md and injected by the global-memory-load.sh
hook, so it is loaded ONLY when the hostname matches. Tracked in git and synced to every
machine, but inert on the others. Put machine-specific facts here: installed
tooling, local paths, hardware quirks, per-host overrides. Do NOT put secrets
here (this file is tracked in git).
-->

## Environment

- **This box = `ME-G614JV`** — the **native Windows** hostname of the **ASUS ROG
  G16 (2024)** laptop (model G614JV). Windows 11, Git Bash / PowerShell. Claude
  Code reads `C:\Users\methe\.claude`. Distinct machine from the ROG G15 2023
  server `methe-server`.
- **Sibling identity: `g614jv`** — the SAME physical laptop seen from inside
  **WSL (Ubuntu)** (mesh peer `me-g614jv`, mesh IP `.6`). See `hosts/g614jv.md`.
  The hostname disambiguates: `ME-G614JV` = native Windows, `g614jv` = inside WSL.
- **Retired former identity: `g16`** — this laptop once ran NixOS as `g16`
  (retired/removed; Windows-only now). Machine-config `hosts/g16/` is kept in
  `machines` (`windows/` only); old `hosts/g16.md` agent memory was deleted.

## Notes

## Claude config bootstrap

- Claude Code runs on win32 and reads `C:\Users\methe\.claude`. To (re)link the
  tracked config there, run the bootstrap through **Git Bash** (`HOME=C:\Users\methe`):
  `& "C:\Program Files\Git\bin\bash.exe" agents/bootstrap.sh`.
- Do NOT run `bash agents/bootstrap.sh` from PowerShell — that `bash` resolves to
  **WSL's**, whose `HOME=/home/me`, so it links the repo into the WSL home instead
  of the Windows `.claude` that Claude Code actually uses. Symptom: a newly-added
  hooks/skills/agents entry shows up missing on Windows (e.g. the SessionStart
  `gortex-onboard-check.sh` "No such file or directory" error) even though a WSL
  bootstrap reported success.

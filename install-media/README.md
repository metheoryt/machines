# install-media — shared Windows 11 install media

Tracked config for the **Ventoy install USB** (the Kingston XS2000, partition
`P:`). Applies to **every** Win11 machine in the fleet — the `g16` daily driver
and the `homeserver` (`methe-server`). The answer file is generic: it prompts
for the computer name at install time, so one file serves all machines.

## Files

| Repo file          | Deploy to                     | Purpose                                        |
|--------------------|-------------------------------|------------------------------------------------|
| `autounattend.xml` | `P:\unattend\autounattend.xml` | Win11 answer file (locale, debloat, RDP, bypass) |
| `ventoy.json`      | `P:\ventoy\ventoy.json`        | Ventoy Auto Install plugin: maps the Win11 ISO → the answer file |

**This repo is source of truth.** After editing either file, copy it to the USB
path above so the two stay in sync.

## Not tracked (recreatable)

- The Windows ISO (`Win11_25H2_Russian_x64_v2.iso`) and the other ISOs on `P:`.
- `P:\rsti\` — Intel RST/VMD storage drivers (from Intel/ASUS), needed on the
  install disk screen when VMD is on.

## Deploy

Mount the Ventoy USB as `P:`, then from a checkout of this repo:

```powershell
Copy-Item install-media\autounattend.xml P:\unattend\autounattend.xml -Force
Copy-Item install-media\ventoy.json      P:\ventoy\ventoy.json        -Force
```

The g16 reinstall runbook (`hosts/desktop/windows/windows-reinstall-runbook.md`)
walks the full boot → install → restore flow that uses this media.

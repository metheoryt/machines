# g16-wsl — the Ubuntu distro on `g16`

Host-local state for the one remaining self-declared WSL host. It has no
`fleet.json` entry (a gitignored `fleet.local.json` instead), so it has no
`hosts/<logical-name>/` of its own — it lives under its Windows parent.

**The WSL distro is still REGISTERED as `desktop-wsl`** and stays that way: the
2026-09-12 rename moved the fleet nickname, not the Windows registration. Nothing
needs them to match — `fd_wsl_hosts` reads the distro name from `wsl -l -q` live
and pairs it with whatever nickname `fleet.local.json` declares, so the dispatch
target is `g16:desktop-wsl`. Renaming the registration means export/import or a
registry edit, and would move `\\wsl$\<name>` paths and Docker Desktop's
integration list with it, for nothing.

## `ssh-socket-override.conf` — the port-22 loss

Install as `/etc/systemd/system/ssh.socket.d/override.conf`:

```console
sudo install -Dm644 hosts/g16/wsl/ssh-socket-override.conf \
     /etc/systemd/system/ssh.socket.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart ssh.socket
```

`.wslconfig` puts this distro in `networkingMode=mirrored`, so it shares the
Windows adapters and `ssh.socket` lost the bind on `0.0.0.0:22` to the Windows
OpenSSH server. systemd reported that as `Dependency failed for ssh.service` on
every boot from 2026-08-29, and **nothing looked for five weeks** while the repo
documented the box as reachable. The drop-in moves it to 2222.

The file spells out **both address families** deliberately: a bare
`ListenStream=2222` bound only `[::]:2222` here, and an IPv4 client got
`Connection refused` rather than a timeout — a different symptom from the
firewall's, which is what made it worth two debugging rounds.

Reaching it from another box **over the LAN** also needs an inbound Windows
firewall rule, because in mirrored mode the Windows firewall governs the
distro's ports. Over the tailnet no rule is needed. Present on g16 as
`wsl-ssh-2222`; to recreate, from an elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName 'wsl-ssh-2222' -Direction Inbound `
  -Action Allow -Protocol TCP -LocalPort 2222 -RemoteAddress 192.168.8.0/24
```

**Do not "fix" this by reverting `networkingMode`.** NAT breaks the WSL
projects' reach to the VPN-only `10.99.x` hosts, which is why mirrored was
chosen; the distro's `.wslconfig` comment records that.

**This is tracked, not provisioned.** Nothing installs it — reprovisioning
g16-wsl still does not restore it. `provision/wsl-fixes.sh` is where it
belongs, gated on the actual precondition (mirrored networking plus port 22
already taken) rather than on the distro's name, and the firewall rule needs a
Windows-side arm that `wsl-fixes.sh` currently has no business issuing. That is
a behaviour change to a script every WSL distro runs, so it wants its own change
and its own suite — roadmap P6.

## Reaching the distro at all

It is **`dispatch:parent`** since 2026-08-31: `fd_probe`/`fd_run` reach it as
`wsl.exe -d desktop-wsl` through `g16`, not over the network. While it was
declared `dispatch:direct`, every fleet-wide run resolved the name, got refused,
and printed `SKIP unreachable` under a green summary. A successful `tailscale
ping` proves nothing about reachability here.

Its own tailnet node (`100.64.0.6`) is still registered and no longer
load-bearing.

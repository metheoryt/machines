## Moving personal projects onto g15 — the WSL traps that cost the most (2026-08-28)

Context: `~/my/` — eleven repos, including qaz-code and its 186 GB pgvector DB —
moved from `desktop-wsl` to `g15-wsl`, and the desktop copies were then deleted.
**Both ends of that route are dead**: g15 was wiped to native Ubuntu 2026-09-07
and the live fleet numbers are in AGENTS.md's *One LAN, not two*. The per-repo
forensics are gone; what recurs for the next big move is below.

### WSL as a fleet host

- **A WSL distro lives only while a `wsl.exe` client from Windows is attached to
  it.** There is no config switch for "stay running" — `vmIdleTimeout` governs
  the utility VM, not the distro. g15-wsl self-terminated about a minute after
  every command returned and kept dropping off the tailnet, which reads as a
  flaky host. **desktop-wsl looks immune only because Docker Desktop's
  `docker-desktop-user-distro proxy --distro-name desktop-wsl` runs inside it and
  is exactly such an attached client — so "drop Docker Desktop, install native
  docker" removes the thing holding desktop-wsl up.** A host that must stay
  reachable needs a Windows scheduled task (ONLOGON, `/RL HIGHEST`) running
  `wsl -d <distro> -u root -- /bin/sleep infinity`; `provision-wsl` installs
  nothing of the sort.
- **Docker Desktop leaves a dpkg diversion behind.** On a distro that ever had DD
  integration, `/usr/bin/docker` is diverted to `/usr/bin/docker.native`, so
  installing `docker.io` yields a working daemon and no CLI at all —
  `docker: command not found` with `dockerd` active. Undo with
  `dpkg-divert --rename --remove /usr/bin/docker`. Re-enabling DD integration
  will re-divert it.
- **A NATed WSL2 distro is unreachable at its own `172.x` address even from its
  own Windows host** — ICMP passes, TCP does not, and it stays broken with an
  explicit Hyper-V firewall allow for the port *and* `DefaultInboundAction
  Allow`, so `netsh portproxy` into the distro does not work either. Measured on
  g15-wsl; `desktop-wsl` is exempt only by `networkingMode=mirrored`. What works
  is jumping through Windows: `ProxyCommand ssh <winuser>@<host> "wsl -d <distro>
  -- nc 127.0.0.1 22"` gives a real ssh connection, rsync included.
- **Piping binary through Windows OpenSSH → PowerShell → `wsl.exe` does NOT
  corrupt the stream.** Verified by sha256 over 100 MB and then 186 GB at
  117 MB/s — PowerShell passes the stdin handle to the child rather than reading
  it. Simplest fast path into a distro, and it needs no port plumbing.
- **But PowerShell eats quotes in a remote command line.** `wsl -d <distro> --
  find … -printf "%s\t%P\n"` silently returns one line. **Feed the script on
  stdin instead** — `printf '%s\n' … | ssh host "wsl -d <distro> -u root --
  bash -s"`. Same mechanism as the tar pipe above.
- **A relayed pair cannot be fixed with a faster radio; only by leaving the
  relay.** Two NATed WSL distros had no direct path and sat at 3.3 MB/s through
  hub's DERP in Kazakhstan — unchanged after both laptops moved to a 1201 Mbps
  WiFi 6 rate. NAT blocks reaching *in*, not going out, so the winning route was
  always the distro **pushing outbound** to a LAN address (78 MB/s), or the LAN
  route through the Windows host's sshd into `wsl.exe` (44 MB/s, 13x the relay,
  same radio). A direct Ethernet cable on APIPA (169.254.x, no DHCP) gave
  117 MB/s and turned 8 hours into 40 minutes.
- **Two traps that produced three false zero-byte "measurements":** `ssh` to a
  **bare IP** does not pick up the fleet identity (the generated config keys on
  `Host *.gg.ez`) — pass `-i ~/.ssh/id_fleet -o IdentitiesOnly=yes`, or it fails
  in 0.2 s having transferred nothing, which looks exactly like no bandwidth. And
  **only port 22 is open inbound** on a Windows box, so `nc` to any port you pick
  is refused and the transfer must ride ssh.

### Moving a repo tree — the gates that earned their place

- **Verify a physical copy by manifest, never by `du`** — path+size for every
  file, sorted `LC_ALL=C` on both sides. `du` totals match even when one file is
  truncated, which is exactly the failure a killed tar produces. Move the payload
  in **chunked** batches with a marker per batch (18 × 10 GB for the 185 GB
  PGDATA) so an interruption costs one batch and the script resumes.
- **The real payload of a repo move is what git ignores.** `git status
  --porcelain` reported all eleven repos clean while ~50 MB of unrecoverable
  content sat on disk: `.env` × 4, a Google service-account key, two SQLite
  harvester DBs, a 12-byte restic password, 62 files of plans and review diffs,
  `.claude/settings.local.json` × 5. Enumerate with `git status --porcelain
  --ignored=matching` **plus** the untracked lines — neither alone is complete —
  except that **`--ignored` without a mode is the listing you actually want**,
  because `--ignored=matching` **does not recurse into an ignored directory**.
  Copy by explicit file list and verify by sha256. Venvs are skipped on purpose;
  `uv sync` rebuilds them.
- **A wholesale `rsync -aH` *including* `.git` is right for a repo with no
  remote.** `DeMarket` and `housing` were the only irreplaceable things in the
  migration and also the two smallest, which is exactly how they get skipped.
  Verify by sha256 over every file: identical except `.git/index` on both sides.
  That file stores stat data (inode, ctime) and **differs across a correct
  copy** — an index-only diff is a pass, not a failure.
- **The pre-delete gate is four commands, and each catches something the others
  cannot:**

      git -C <repo> rev-list --branches --not --remotes   # unpushed commits
      git -C <repo> stash list                            # stashes
      git -C <repo> worktree list                         # worktrees
      grep -rl '/home/me/my/' ~/.config/systemd/user/ /etc/systemd/system/

  HEAD comparison alone misses a second branch — four of the eleven had one.
  **A worktree's uncommitted state is invisible from the main repo's `git
  status`, and its existence is invisible from `for-each-ref`**: refs, stashes
  and HEAD all came back clean and deleting `~/my/` still orphaned three Orca
  worktrees under `~/orca/workspaces/<repo>/<branch>`, whose `.git` files point
  into the parent that went away. The `grep` catches live infrastructure that
  happens to live in a project checkout — a unit's `WorkingDirectory`. That is
  why `~/my/vps` was spared on desktop-wsl (the timer
  `resticprofile-backup@profile-wsl.service`); **that particular reason is
  superseded** — the restic profiles moved into `machines/backup/<identity>/` on
  2026-09-01 — but whether the live unit was re-pointed is only visible on the
  box, so re-run the `grep` there rather than assuming either way.
- **Recovering an orphaned worktree:** its *files* survive the parent's deletion.
  Re-create the parent, `git worktree add <path> <branch>` for a clean checkout
  at the tip, then rsync the orphaned directory over it excluding `.git` —
  whatever `git status` then reports IS the uncommitted work, and an empty status
  proves nothing was lost. To check an orphan with **no** repo at all, compute
  git blob hashes by hand —

      { printf 'blob %d\0' $(stat -c%s "$f"); cat "$f"; } | sha1sum

  — and diff against `git ls-tree -r --format='%(objectname) %(path)'` on the
  branch. That is how one orphan was cleared: 36 files, every blob identical to
  `origin/main`, so the branch had been merged and only its name was lost.
- **`rsync --exclude '.git'` silently strips nested repositories.** Excluding
  `.git` when copying a worktree is right — the worktree's own `.git` is a
  pointer file that must not travel — but it takes nested repos with it, and the
  copy still reports **`rc=0`**. One qaz-code worktree carried four nested repos
  (139 653 commits, 1.8 GB, none with a remote) inside an untracked `laws/` tree,
  itself regenerable from qaz-code's database. Caught by a plain **file-count
  diff** after the transfer, not by the exit status. **Count files across the
  boundary; an rsync that succeeded is not an rsync that copied what you meant.**
  Before excluding `.git` anywhere, run `find <tree> -name .git -maxdepth 4` and
  decide about each hit by name.
- **Deleting a docker volume returns no bytes to Windows.** `docker_data.vhdx` is
  a dynamically-expanding VHD and never shrinks on its own — a 200.9 GB →
  2.047 GB drop in Docker's `Local Volumes` left it at 1007 GB. Reclaiming it
  needs Docker Desktop stopped and an elevated `diskpart` (`select vdisk file=…`
  → `attach vdisk readonly` → `compact vdisk` → `detach vdisk`), or
  `Optimize-VHD -Mode Full`. Worth knowing before promising anyone that a volume
  delete freed disk space.

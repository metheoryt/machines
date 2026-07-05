#!/usr/bin/env bash
# Claude Code compact status line (~70 visible chars)
# Requires: python3 (or python — auto-detected), git
# Layout: 📁proj 🌿branch↑a↓b+S~U?N │ 🎼Opus │ ⏳▅42%·3h 📆▁5%·6d │ 🧠▂8%
#   gauges use a single sparkline char (▁▂▃▄▅▆▇█) to encode fill compactly
#   🎼/📝/🍃/📖 = model family (Opus/Sonnet/Haiku/Fable)
#   ↑a↓b on the branch = commits ahead/behind the upstream remote
#   ⏳=5h limit  📆=7d limit  🧠=context window
#   🕸=gortex code-graph daemon (green=ready & cwd indexed · 🕸?=up, cwd not indexed · 🕸…=warming · 🕸✗=down)
#   "·" before a duration means "resets in"; value colored by severity

input=$(cat)

# Python on Windows defaults to a non-UTF-8 codec; force UTF-8 so the
# sparkline/bar glyphs survive both source parsing and stdout.
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

# Resolve a working Python interpreter. Prefer python3 (macOS/Linux), but on
# Windows `python3`/`python` are often Microsoft Store stubs that just print an
# install message and exit non-zero — so test that each actually runs (`-c ''`)
# before committing to it. The `py` launcher is the reliable Windows fallback:
# it finds real installs via the registry regardless of PATH order (the Store
# stubs in WindowsApps usually shadow the real python.exe on PATH).
PY=""
for _py in python3 python py; do
  if command -v "$_py" >/dev/null 2>&1 && "$_py" -c '' >/dev/null 2>&1; then
    PY="$_py"; break
  fi
done
[ -z "$PY" ] && PY=python

# ── ANSI colors ───────────────────────────────────────────────────────────────
R='\033[0;31m'; Y='\033[0;33m'; G='\033[0;32m'; C='\033[0;36m'
B='\033[0;34m'; M='\033[0;35m'; DIM='\033[2m'; RESET='\033[0m'

# ── OSC 8 hyperlink: real ESC bytes so terminals render <label> as clickable ──
# Emits  ESC]8;;<url>ESC\ <label> ESC]8;;ESC\  — terminals that support OSC 8
# (iTerm2, WezTerm, kitty, VTE, Windows Terminal) make <label> a link; others
# just show <label>. The final output uses printf '%s' so these bytes survive.
hyperlink() { printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"; }

# ── Extract a JSON field by dotted path ───────────────────────────────────────
jget() {
  printf '%s' "$input" | "$PY" -c "
import sys, json
try:
    v = json.load(sys.stdin)
    for p in '$1'.split('.'):
        if not p: continue
        v = v.get(p) if isinstance(v, dict) else None
        if v is None: break
    if v is not None and v is not False:
        print(v, end='')
except: pass
" 2>/dev/null
}

# ── Single sparkline char for a 0-100 value ──────────────────────────────────
spark() {
  "$PY" -c "
p=max(0.0,min(100.0,float($1)))
print('▁▂▃▄▅▆▇█'[min(7,int(p*8/100))], end='')
" 2>/dev/null || printf '?'
}

# ── Color by percentage: green <50, yellow 50-79, red >=80 ───────────────────
pct_color() {
  "$PY" -c "
p=float($1)
print('\033[0;31m' if p>=80 else '\033[0;33m' if p>=50 else '\033[0;32m', end='')
" 2>/dev/null
}

# ── Compact reset countdown from unix epoch seconds ──────────────────────────
countdown() {
  "$PY" -c "
import time
d=int($1)-int(time.time())
print('now' if d<=0 else f'{d//86400}d' if d>=86400 else f'{d//3600}h' if d>=3600 else f'{d//60}m', end='')
" 2>/dev/null || printf '?'
}

# ── Truncate to N chars with ellipsis ────────────────────────────────────────
trunc() {
  local s="$1" n="$2"
  if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$((n-1))}"; else printf '%s' "$s"; fi
}

round() { "$PY" -c "print(round(float($1)), end='')" 2>/dev/null; }

# ── Map a model name/id to a family glyph + short label ──────────────────────
model_glyph_name() {
  local n
  n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$n" in
    *opus*)   printf '🎼Opus' ;;
    *sonnet*) printf '📝Sonnet' ;;
    *haiku*)  printf '🍃Haiku' ;;
    *fable*)  printf '📖Fable' ;;
    *)        printf '🤖%s' "$(trunc "$1" 10)" ;;
  esac
}

# ── Latest auto-generated session title, read from the transcript ────────────
# Claude writes recurring "ai-title" entries; we want the most recent one.
# Scan only the tail for speed, fall back to the whole file if none found there.
session_title() {
  local tp="$1"
  [ -z "$tp" ] && return
  "$PY" - "$tp" <<'PY' 2>/dev/null
import sys, os, json
tp = sys.argv[1] if len(sys.argv) > 1 else ''
if not tp or not os.path.exists(tp):
    sys.exit()
sz = os.path.getsize(tp)
def scan(lines):
    title = None
    for line in lines:
        if '"ai-title"' not in line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get('type') == 'ai-title' and o.get('aiTitle'):
            title = o['aiTitle']
    return title
with open(tp, 'r', encoding='utf-8', errors='ignore') as fh:
    if sz > 200000:
        fh.seek(sz - 200000)
        fh.readline()  # drop the partial first line after seeking
    t = scan(fh)
if t is None and sz > 200000:
    with open(tp, 'r', encoding='utf-8', errors='ignore') as fh:
        t = scan(fh)
if t:
    print(t, end='')
PY
}

# ── Account email local-part + plan, so multiple profiles are distinguishable ─
# Reads the same config the running session uses (honors CLAUDE_CONFIG_DIR).
profile_id() {
  "$PY" - <<'PY' 2>/dev/null
import os, json
cands = []
cfg = os.environ.get('CLAUDE_CONFIG_DIR')
if cfg:
    cands.append(os.path.join(cfg, '.claude.json'))
cands.append(os.path.join(os.path.expanduser('~'), '.claude.json'))
acc = None
for p in cands:
    try:
        acc = json.load(open(p, encoding='utf-8')).get('oauthAccount')
    except Exception:
        acc = None
    if acc:
        break
if not acc:
    raise SystemExit
email = acc.get('emailAddress') or ''
user = email.split('@')[0] if email else (acc.get('displayName') or '')
otype = (acc.get('organizationType') or '').lower()
plan = {
    'claude_pro': 'Pro', 'claude_max': 'Max', 'claude_team': 'Team',
    'claude_enterprise': 'Ent', 'claude_free': 'Free',
}.get(otype, otype.replace('claude_', '').title() if otype else '')
print((user + '·' + plan) if (user and plan) else (user or plan), end='')
PY
}

# ── API / pay-as-you-go billing? (vs flat-rate Claude subscription) ───────────
# The cost segment only makes sense for token-billed usage. We show it unless the
# session is on a flat-rate consumer subscription (Pro/Max/Team/Enterprise/Free),
# where per-token cost is meaningless. Signals, in order:
#   1) ANTHROPIC_API_KEY in env  -> API billing
#   2) oauthAccount.organizationType in the subscription set -> hide
#   3) anything else (Console/dev OAuth with orgType None, or no account) -> show
# (Note: Claude Code may strip ANTHROPIC_API_KEY from this subprocess, so the
# orgType check is the load-bearing one.) Prints "1" when the segment should show.
is_api_key_login() {
  "$PY" - <<'PY' 2>/dev/null
import os, json
if os.environ.get('ANTHROPIC_API_KEY'):
    print('1', end=''); raise SystemExit
SUBSCRIPTION = {'claude_pro', 'claude_max', 'claude_team',
                'claude_enterprise', 'claude_free'}
cands = []
cfg = os.environ.get('CLAUDE_CONFIG_DIR')
if cfg:
    cands.append(os.path.join(cfg, '.claude.json'))
cands.append(os.path.join(os.path.expanduser('~'), '.claude.json'))
acc = None
for p in cands:
    try:
        acc = json.load(open(p, encoding='utf-8')).get('oauthAccount')
    except Exception:
        acc = None
    if acc:
        break
otype = ((acc or {}).get('organizationType') or '').lower()
if otype not in SUBSCRIPTION:  # API key, dev OAuth, or unknown => show
    print('1', end='')
PY
}

# ── Sum tokens across the transcript's usage records ──────────────────────────
# Splits the input side into fresh (full-price) vs cached (cache-create + read,
# cheap). Emits "<fresh> <cached> <output>" (whitespace-separated integers).
token_totals() {
  local tp="$1"
  [ -z "$tp" ] && return
  "$PY" - "$tp" <<'PY' 2>/dev/null
import sys, os, json
tp = sys.argv[1] if len(sys.argv) > 1 else ''
if not tp or not os.path.exists(tp):
    sys.exit()
fresh = cached = out = 0
with open(tp, 'r', encoding='utf-8', errors='ignore') as fh:
    for line in fh:
        if '"usage"' not in line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        msg = o.get('message') if isinstance(o, dict) else None
        u = msg.get('usage') if isinstance(msg, dict) else None
        if not isinstance(u, dict):
            continue
        fresh += (u.get('input_tokens') or 0)
        cached += ((u.get('cache_creation_input_tokens') or 0)
                   + (u.get('cache_read_input_tokens') or 0))
        out += (u.get('output_tokens') or 0)
print(f"{fresh} {cached} {out}", end='')
PY
}

# ── Compact token count: 1234→1.2k, 1500000→1.5M ─────────────────────────────
humanize() {
  "$PY" -c "
n=float($1)
print(f'{n/1e6:.1f}M' if n>=1e6 else f'{n/1e3:.1f}k' if n>=1e3 else str(int(n)), end='')
" 2>/dev/null || printf '?'
}

# ── Per-1M input/output USD rate by model family ─────────────────────────────
model_rate() {
  local n
  n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$n" in
    *opus*)   printf '$5/$25' ;;
    *sonnet*) printf '$3/$15' ;;
    *haiku*)  printf '$1/$5' ;;
    *fable*)  printf '$10/$50' ;;
    *)        printf '$5/$25' ;;
  esac
}

# ── Remaining-balance segment from the anchor + cached spend ──────────────────
# Emits "<remaining>\t<spent>\t<need_refresh>\t<source>" (│-separated). Three
# modes, in priority order:
#   admin  : single local anchor, spend from the org Cost Report (source=admin)
#   shared : $CLAUDE_BUDGET_DIR set & no admin key — anchor.json in the synced
#            folder, remaining = balance − Σ spend-*.json (only files whose
#            set_at matches the anchor; stale ones count as 0). source=shared.
#   local  : single local anchor, spend estimated from transcripts (source=local)
# Falls back to the static $CLAUDE_API_BALANCE when no anchor is set. A leading
# "~" on the remaining means spend hasn't been computed yet (first run / this
# device hasn't reported into the shared ledger).
balance_segment() {
  "$PY" - <<'PY' 2>/dev/null
import os, json, time, glob
base = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(
    os.path.expanduser('~'), '.claude')
budget = os.environ.get('CLAUDE_BUDGET_DIR')
admin_key = os.environ.get('ANTHROPIC_ADMIN_KEY')
# Admin (global) spend is daily-bucketed and lags, so refresh it rarely; the
# local/shared estimates are cheap, so keep them fresh.
TTL = {'admin': 1800, 'local': 60, 'shared': 60}

def device_id():
    import socket, re
    name = os.environ.get('COMPUTERNAME') or socket.gethostname() or 'device'
    return re.sub(r'[^A-Za-z0-9_-]', '-', name) or 'device'

# ── Shared (cloud-synced) ledger. Takes priority over the local anchor, but an
# admin key wins outright (it's authoritative org-wide on its own). ────────────
if budget and not admin_key:
    try:
        a = json.load(open(os.path.join(budget, 'anchor.json'), encoding='utf-8'))
        bal = float(a['balance']); set_at = float(a.get('set_at', 0))
    except Exception:
        raise SystemExit  # no shared anchor yet → show nothing
    me = os.path.abspath(os.path.join(budget, 'spend-%s.json' % device_id()))
    total = 0.0
    me_fresh = False
    for fp in glob.glob(os.path.join(budget, 'spend-*.json')):
        try:
            s = json.load(open(fp, encoding='utf-8'))
        except Exception:
            continue
        # Only count devices anchored to the SAME baseline; files left over from
        # before the last re-anchor count as 0 until that device catches up.
        if abs(float(s.get('set_at', -1)) - set_at) > 1e-6:
            continue
        total += float(s.get('spent', 0) or 0)
        if os.path.abspath(fp) == me:
            me_fresh = (time.time() - float(s.get('computed_at', 0))) < TTL['shared']
    need = '0' if me_fresh else '1'   # refresh recomputes THIS device's spend
    prefix = '' if me_fresh else '~'  # ~ = this device hasn't reported yet
    print(f"{prefix}${bal - total:.2f}|${total:.2f}|{need}|shared", end='')
    raise SystemExit

# ── Single-device anchor (admin or local). ────────────────────────────────────
anchor = os.path.join(base, 'api-balance.json')
cache = os.path.join(base, 'api-balance.cache.json')
try:
    a = json.load(open(anchor, encoding='utf-8'))
    bal = float(a['balance']); set_at = float(a.get('set_at', 0))
except Exception:
    env = os.environ.get('CLAUDE_API_BALANCE')
    if env:
        print(f"{env}||0|", end='')  # static value, no spend, no refresh
    raise SystemExit
spent = None; fresh = False; src = ''
try:
    c = json.load(open(cache, encoding='utf-8'))
    if abs(float(c.get('set_at', -1)) - set_at) < 1e-6:
        spent = float(c.get('spent', 0))
        src = c.get('source', 'local')
        fresh = (time.time() - float(c.get('computed_at', 0))) < TTL.get(src, 60)
except Exception:
    pass
need = '0' if fresh else '1'
if spent is None:
    print(f"~${bal:.2f}||{need}|", end='')  # not computed yet
else:
    print(f"${bal - spent:.2f}|${spent:.2f}|{need}|{src}", end='')
PY
}

# ── Fields ────────────────────────────────────────────────────────────────────
cwd=$(jget "cwd")
project_dir=$(jget "workspace.project_dir")
transcript_path=$(jget "transcript_path")
model_name=$(jget "model.display_name")
[ -z "$model_name" ] && model_name=$(jget "model.id")
ctx_pct=$(jget "context_window.used_percentage")
five_pct=$(jget "rate_limits.five_hour.used_percentage")
five_reset=$(jget "rate_limits.five_hour.resets_at")
week_pct=$(jget "rate_limits.seven_day.used_percentage")
week_reset=$(jget "rate_limits.seven_day.resets_at")

# ── 0. Persist soonest subscription window reset ─────────────────────────────
# Claude Code only puts rate_limits in stdin during a *subscription* session
# (incl. a 100%-used one). API-key sessions get nothing. So whenever we DO see
# window data, cache the soonest resets_at to a file; the API-key segment below
# reads it back to show "when can I switch off the API key". Fully supported —
# we only persist data Claude Code already gave us, no token/endpoint hacks.
if [ -n "$five_reset" ] || [ -n "$week_reset" ]; then
  "$PY" - "$five_reset" "$week_reset" "$five_pct" "$week_pct" <<'PY' 2>/dev/null
import sys, os, json, time
base = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.claude')
def num(x):
    try: return float(x)
    except Exception: return None
fr = num(sys.argv[1]) if len(sys.argv) > 1 else None
wr = num(sys.argv[2]) if len(sys.argv) > 2 else None
fp = num(sys.argv[3]) if len(sys.argv) > 3 else None
wp = num(sys.argv[4]) if len(sys.argv) > 4 else None
wins = []
if fr: wins.append(('5h', fr, fp))
if wr: wins.append(('7d', wr, wp))
if not wins:
    raise SystemExit
label, resets_at, pct = min(wins, key=lambda w: w[1])
out = {'label': label, 'resets_at': resets_at, 'pct': pct, 'updated_at': time.time()}
try:
    with open(os.path.join(base, 'window-reset.json'), 'w', encoding='utf-8') as fh:
        json.dump(out, fh)
except Exception:
    pass
PY
fi

# ── 1. Project name (+ worktree flag) ────────────────────────────────────────
# Prefer the CANONICAL repo name from git's *common* dir, so 📁 stays stable
# (e.g. "kan-kan") no matter which linked worktree we're in. A linked worktree's
# per-tree git dir differs from the common dir → flag it with 🌲. Outside a repo,
# fall back to the workspace/cwd basename.
name=""
wt_flag=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  gitdir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)
  commondir=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
  case "$commondir" in
    /* | [A-Za-z]:* ) : ;;                                         # already absolute
    * ) commondir=$(cd "$cwd" && cd "$commondir" 2>/dev/null && pwd) ;;
  esac
  if [ -n "$commondir" ]; then
    name=$(basename "$(dirname "$commondir")")
    [ -n "$gitdir" ] && [ "$gitdir" != "$commondir" ] && wt_flag=" 🌲"
  fi
fi
[ -z "$name" ] && [ -n "$project_dir" ] && name=$(basename "$project_dir")
[ -z "$name" ] && [ -n "$cwd" ] && name=$(basename "$cwd")
project_str=""
[ -n "$name" ] && project_str="📁$(trunc "$name" 14)${wt_flag}"

# ── 2. Git branch + dirty counts ─────────────────────────────────────────────
git_str=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
           || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    staged=0; unstaged=0; untracked=0
    while IFS= read -r line; do
      x="${line:0:1}"; y="${line:1:1}"
      if [ "$x" = "?" ] && [ "$y" = "?" ]; then (( untracked++ ))
      else
        [ "$x" != " " ] && [ "$x" != "?" ] && (( staged++ ))
        [ "$y" != " " ] && [ "$y" != "?" ] && (( unstaged++ ))
      fi
    done < <(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
    dirty=""
    [ "$staged"    -gt 0 ] && dirty="${dirty}+${staged}"
    [ "$unstaged"  -gt 0 ] && dirty="${dirty}~${unstaged}"
    [ "$untracked" -gt 0 ] && dirty="${dirty}?${untracked}"
    # commits ahead/behind upstream: rev-list left-right = "behind<TAB>ahead"
    ab=""
    upstream=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
    if [ -n "$upstream" ]; then
      behind=$(printf '%s' "$upstream" | awk '{print $1}')
      ahead=$(printf '%s' "$upstream" | awk '{print $2}')
      [ "${ahead:-0}"  -gt 0 ] 2>/dev/null && ab="${ab}↑${ahead}"
      [ "${behind:-0}" -gt 0 ] 2>/dev/null && ab="${ab}↓${behind}"
    fi
    git_str=$(printf "🌿${C}$(trunc "$branch" 30)${ab}${dirty}${RESET}")
  fi
fi

# ── 2b. Jira ticket + GitHub PR links for the branch (clickable, OSC 8) ───────
# Jira key parsed from the branch (…/CFT-1234-…) → thepureapp browse URL.
# PR read from a short-TTL cache; a stale/missing cache kicks a detached,
# lock-guarded `gh pr view` refresh so the status line never blocks on the net.
# Glyph tracks review state: 🔀 open · ✅ approved · 🔧 changes requested · 📝 draft.
link_str=""
if [ -n "$branch" ]; then
  jira=$(printf '%s' "$branch" | grep -Eio 'CFT-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')
  if [ -n "$jira" ]; then
    link_str=$(printf "${Y}🎫%s${RESET}" "$(hyperlink "https://thepureapp.atlassian.net/browse/$jira" "$jira")")
  fi
fi
if [ -n "$branch" ] && [ -n "$cwd" ] && command -v gh >/dev/null 2>&1; then
  root=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$root" ]; then
    cache_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/pr-cache"
    mkdir -p "$cache_dir" 2>/dev/null
    key=$(printf '%s|%s' "$root" "$branch" | cksum | cut -d' ' -f1)
    cache_file="$cache_dir/$key.json"; PR_TTL=300; age=999999
    if [ -f "$cache_file" ]; then
      mtime=$(date -r "$cache_file" +%s 2>/dev/null); [ -z "$mtime" ] && mtime=0
      age=$(( $(date +%s) - mtime ))
      read -r pr_num pr_url pr_state < <("$PY" - "$cache_file" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
num, url = d.get("number"), d.get("url")
if num and url:
    rd = (d.get("reviewDecision") or "").upper()
    state = ("draft" if d.get("isDraft") else "approved" if rd == "APPROVED"
             else "changes" if rd == "CHANGES_REQUESTED" else "open")
    print(num, url, state)
PYEOF
)
      if [ -n "${pr_num:-}" ]; then
        glyph="🔀"
        [ "$pr_state" = "approved" ] && glyph="✅"
        [ "$pr_state" = "changes" ] && glyph="🔧"
        [ "$pr_state" = "draft" ] && glyph="📝"
        pr_seg=$(printf "${G}%s%s${RESET}" "$glyph" "$(hyperlink "$pr_url" "#$pr_num")")
        [ -n "$link_str" ] && link_str="$link_str "
        link_str="$link_str$pr_seg"
      fi
    fi
    # Stale/missing cache → refresh once in the background (never block here).
    if [ "$age" -ge "$PR_TTL" ]; then
      lock="$cache_file.lock"; lock_age=999999
      if [ -f "$lock" ]; then
        lmtime=$(date -r "$lock" +%s 2>/dev/null); [ -z "$lmtime" ] && lmtime=0
        lock_age=$(( $(date +%s) - lmtime ))
      fi
      if [ "$lock_age" -ge 60 ]; then
        : > "$lock" 2>/dev/null
        (
          cd "$root" 2>/dev/null || exit
          pr_json=$(gh pr view --json number,url,reviewDecision,isDraft 2>/dev/null)
          [ -z "$pr_json" ] && pr_json='{}'
          printf '%s' "$pr_json" > "$cache_file.tmp" 2>/dev/null \
            && mv "$cache_file.tmp" "$cache_file" 2>/dev/null
          rm -f "$lock" 2>/dev/null
        ) >/dev/null 2>&1 &
        disown 2>/dev/null || true
      fi
    fi
  fi
fi

# ── 3. Model family glyph + name ─────────────────────────────────────────────
model_str=""
[ -n "$model_name" ] && model_str=$(printf "${DIM}$(model_glyph_name "$model_name")${RESET}")

# ── 4. Rate-limit gauges (sparkline + % + reset) ─────────────────────────────
rl_str=""
if [ -n "$five_pct" ] && [ -n "$five_reset" ]; then
  rl_str="$(printf "${C}⏳${RESET}$(pct_color "$five_pct")$(spark "$five_pct")$(round "$five_pct")%%·$(countdown "$five_reset")${RESET}")"
fi
if [ -n "$week_pct" ] && [ -n "$week_reset" ]; then
  [ -n "$rl_str" ] && rl_str="${rl_str} "
  rl_str="${rl_str}$(printf "${B}📆${RESET}$(pct_color "$week_pct")$(spark "$week_pct")$(round "$week_pct")%%·$(countdown "$week_reset")${RESET}")"
fi

# ── 5. Context window gauge ───────────────────────────────────────────────────
ctx_str=""
if [ -n "$ctx_pct" ]; then
  ctx_str=$(printf "${M}🧠${RESET}$(pct_color "$ctx_pct")$(spark "$ctx_pct")$(round "$ctx_pct")%%${RESET}")
fi

# ── 5c. gortex code-graph daemon status (cached + bg-refreshed) ───────────────
# 🕸 shows whether the gortex code-intelligence daemon is up and whether THIS cwd
# is indexed. `gortex daemon status` is a Go binary (tens of ms) + it lists the
# tracked repo paths, so we cache its parsed output on a short TTL and refresh it
# in a detached, lock-guarded child — the status line never blocks on it, exactly
# like the PR segment. Guarded on `command -v gortex`, so it vanishes where gortex
# isn't installed. A linked worktree lives outside the tracked repo path, so it
# reads as 🕸? (up, cwd not indexed) — the visible tell that graph tools are dark.
gortex_str=""
if [ -n "$cwd" ] && command -v gortex >/dev/null 2>&1; then
  gcache_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/gortex-cache"
  mkdir -p "$gcache_dir" 2>/dev/null
  gcache="$gcache_dir/status"; G_TTL=30; gage=999999
  if [ -f "$gcache" ]; then
    gmtime=$(date -r "$gcache" +%s 2>/dev/null); [ -z "$gmtime" ] && gmtime=0
    gage=$(( $(date +%s) - gmtime ))
    g_state=""; g_pct="-"
    IFS=' ' read -r g_state g_pct < "$gcache"
    covered=""
    while IFS= read -r rp; do
      [ -z "$rp" ] && continue
      case "$cwd/" in "$rp/"*) covered=1; break ;; esac
    done < <(tail -n +2 "$gcache")
    case "$g_state" in
      ready)
        if [ -n "$covered" ]; then gortex_str=$(printf "${G}🕸${RESET}")
        else gortex_str=$(printf "${Y}🕸?${RESET}"); fi ;;
      down|"")
        gortex_str=$(printf "${DIM}${R}🕸✗${RESET}") ;;
      *)  # warming / indexing / any non-ready phase
        pshow=""; [ -n "$g_pct" ] && [ "$g_pct" != "-" ] && pshow="${g_pct}%"
        gortex_str=$(printf "${Y}🕸…${pshow}${RESET}") ;;
    esac
  fi
  # Stale/missing cache → refresh once in the background (never block here).
  if [ "$gage" -ge "$G_TTL" ]; then
    glock="$gcache.lock"; glock_age=999999
    if [ -f "$glock" ]; then
      glmtime=$(date -r "$glock" +%s 2>/dev/null); [ -z "$glmtime" ] && glmtime=0
      glock_age=$(( $(date +%s) - glmtime ))
    fi
    if [ "$glock_age" -ge 30 ]; then
      : > "$glock" 2>/dev/null
      (
        st=$(timeout 5 gortex daemon status 2>/dev/null)
        if [ -z "$st" ]; then
          printf 'down -\n' > "$gcache.tmp"
        else
          word=$(printf '%s\n' "$st" | awk '/^ *state /{print $2; exit}')
          [ -z "$word" ] && word="down"
          pct=$(printf '%s\n' "$st" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
          [ -z "$pct" ] && pct="-"
          {
            printf '%s %s\n' "$word" "$pct"
            # tracked-repo paths only (skip the MCP-sessions table's cwd column)
            printf '%s\n' "$st" \
              | awk '/^tracked repos:/{t=1;next} /^MCP sessions:/{t=0} t' \
              | awk -F'│' '{for(i=1;i<=NF;i++){p=$i; gsub(/^ +| +$/,"",p); if(p ~ /^\//) print p}}'
          } > "$gcache.tmp"
        fi
        mv "$gcache.tmp" "$gcache" 2>/dev/null
        rm -f "$glock" 2>/dev/null
      ) >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
  fi
fi

# ── 5b. API session: cost · i/o tokens · per-1M rate (API-key login only) ──────
# Balance is intentionally absent: Claude Code's status-line stdin carries no
# credit balance, and there's no synchronous account-balance API to call here.
# Set $CLAUDE_API_BALANCE to surface a number you maintain elsewhere.
# Token-billed (API / prepaid) session? Show cost/balance only then. Two guards:
#  • Claude Code sends rate-limit WINDOWS only in subscription sessions, where
#    per-token cost is meaningless — their presence hides the segment (the
#    authoritative PER-SESSION signal; needed because individual accounts report
#    organizationType=None, so the account-type check alone always shows it). An
#    explicit ANTHROPIC_API_KEY overrides (you're paying per token regardless).
#  • is_api_key_login() still hides known flat-rate account types as a backstop.
session_windows=""
[ -n "$five_reset$week_reset$five_pct$week_pct" ] && session_windows=1
api_billed=""
if [ -z "$session_windows" ] || [ -n "$ANTHROPIC_API_KEY" ]; then
  [ -n "$(is_api_key_login)" ] && api_billed=1
fi
api_str=""
if [ -n "$api_billed" ]; then
  cost=$(jget "cost.total_cost_usd")
  tfresh=""; tcached=""; tout=""
  read -r tfresh tcached tout < <(token_totals "$transcript_path")
  api_parts=""
  if [ -n "$cost" ]; then
    api_parts=$(printf "${G}💵\$%.2f${RESET}" "$cost")
  fi
  if [ -n "$tfresh" ] && [ -n "$tout" ]; then
    # distinct colored markers: cyan ↑ fresh input, yellow ⚡ cached input,
    # magenta ↓ output. Spacing keeps the glyphs from reading as digits.
    io=$(printf "${C}↑${RESET}$(humanize "$tfresh") ${Y}⚡${RESET}$(humanize "$tcached") ${M}↓${RESET}$(humanize "$tout")")
    [ -n "$api_parts" ] && api_parts="$api_parts "
    api_parts="${api_parts}${io}"
  fi
  rate=$(printf "${DIM}$(model_rate "$model_name")·1M${RESET}")
  [ -n "$api_parts" ] && api_parts="$api_parts "
  api_parts="${api_parts}${rate}"
  # 🥷 admin API key present → org-wide (global) cost reporting is available.
  [ -n "$ANTHROPIC_ADMIN_KEY" ] && api_parts="${api_parts} $(printf "${DIM}🥷${RESET}")"
  # remaining balance = anchor − spend-since-anchor (cached; refreshed in bg)
  IFS='|' read -r brem bspent bneed bsrc <<<"$(balance_segment)"
  if [ -n "$brem" ]; then
    # 🌐 = org-wide authoritative (admin); 🔗 = cloud-synced shared ledger
    # (same number on every device, summed across spend-*.json).
    glb=""
    [ "$bsrc" = "admin" ]  && glb=$(printf "${DIM}🌐${RESET}")
    [ "$bsrc" = "shared" ] && glb=$(printf "${DIM}🔗${RESET}")
    seg=$(printf "${glb}${Y}🏦${brem}${RESET}")
    [ -n "$bspent" ] && seg="${seg}$(printf "${DIM}↘${bspent}${RESET}")"
    api_parts="${api_parts} ${seg}"
  fi
  if [ "$bneed" = "1" ]; then
    ( nohup "$PY" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/balance-refresh.py" >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
  # 🪟 Subscription window reset: API-key stdin carries no rate_limits, so read
  # the cache persisted during the last subscription session (section 0) and show
  # the ETA until the soonest window resets — i.e. when to switch back. "ready"
  # (green) once the window has reset. Hidden if we've never seen window data.
  reset_note=""
  win=$("$PY" - <<'PY' 2>/dev/null
import os, json, time
base = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.claude')
try:
    with open(os.path.join(base, 'window-reset.json'), encoding='utf-8') as fh:
        w = json.load(fh)
    ra = float(w['resets_at'])
except Exception:
    raise SystemExit
d = int(ra - time.time())
if d <= 0:
    print('ready', end='')
elif d >= 86400:
    print(f"{d//86400}d{(d%86400)//3600}h", end='')
elif d >= 3600:
    print(f"{d//3600}h{(d%3600)//60}m", end='')
else:
    print(f"{d//60}m", end='')
PY
)
  if [ "$win" = "ready" ]; then
    reset_note=$(printf "${G}🪟ready${RESET}")
  elif [ -n "$win" ]; then
    reset_note=$(printf "${DIM}🪟${win}${RESET}")
  fi
  [ -n "$reset_note" ] && api_parts="${api_parts} ${reset_note}"
  api_str="$api_parts"
fi

# ── 6. Session title (own line) + profile identity (trailing segment) ────────
title_raw=$(session_title "$transcript_path")
title_str=""
[ -n "$title_raw" ] && title_str=$(printf "${DIM}🏷️ $(trunc "$title_raw" 60)${RESET}")

prof=$(profile_id)
profile_str=""
[ -n "$prof" ] && profile_str=$(printf "${DIM}👤${prof}${RESET}")

# ── Assemble with dim │ separators ───────────────────────────────────────────
sep=$(printf "${DIM}│${RESET}")
out=""
for p in "$project_str" "$git_str" "$link_str" "$model_str" "$rl_str" "$ctx_str" "$gortex_str" "$api_str" "$profile_str"; do
  [ -z "$p" ] && continue
  if [ -z "$out" ]; then out="$p"; else out="${out} ${sep} ${p}"; fi
done

# Title on its own first line (when available), then the compact gauges line.
# %s (not %b): every segment above is already built with printf, so its ANSI/OSC
# escapes are real bytes — %b would re-interpret the OSC 8 backslashes and break links.
[ -n "$title_str" ] && printf '%s\n' "$title_str"
printf '%s\n' "$out"

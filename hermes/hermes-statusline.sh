#!/usr/bin/env bash
# Hermes Agent compact status line (~60 visible chars)
# Adapted from agents/statusline-command.sh for Hermes.
#
# Layout: 📁proj 🌿branch↑a↓b+S~U?N │ 🤖model@provider │ 🌀gw │ 🌐serve │ 🕸gortex
#
# Sources:
#   - ~/.hermes/config.yaml        model + provider
#   - ~/.hermes/gateway_state.json  gateway status + active agents
#   - localhost:9119/api/status     serve backend status (when running)
#
# Requires: python3, curl (optional, for serve status), git, gortex (optional)
set -u

# ── Python resolution ─────────────────────────────────────────────────────────
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
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

# ── Helpers ───────────────────────────────────────────────────────────────────
trunc() {
  local s="$1" n="$2"
  if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$((n-1))}"; else printf '%s' "$s"; fi
}

# ── 1. Project name + worktree flag ───────────────────────────────────────────
cwd="${1:-$(pwd)}"
name=""; wt_flag=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  gitdir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)
  commondir=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
  case "$commondir" in
    /* | [A-Za-z]:* ) : ;;
    * ) commondir=$(cd "$cwd" && cd "$commondir" 2>/dev/null && pwd) ;;
  esac
  if [ -n "$commondir" ]; then
    name=$(basename "$(dirname "$commondir")")
    [ -n "$gitdir" ] && [ "$gitdir" != "$commondir" ] && wt_flag=" 🌲"
  fi
fi
[ -z "$name" ] && name=$(basename "$cwd")
project_str="📁$(trunc "$name" 14)${wt_flag}"

# ── 2. Git branch + dirty counts ──────────────────────────────────────────────
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
    ab=""
    upstream=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
    if [ -n "$upstream" ]; then
      behind=$(printf '%s' "$upstream" | awk '{print $1}')
      ahead=$(printf '%s'  "$upstream" | awk '{print $2}')
      [ "${ahead:-0}"  -gt 0 ] 2>/dev/null && ab="${ab}↑${ahead}"
      [ "${behind:-0}" -gt 0 ] 2>/dev/null && ab="${ab}↓${behind}"
    fi
    git_str=$(printf "🌿${C}$(trunc "$branch" 30)${ab}${dirty}${RESET}")
  fi
fi

# ── 3. Model + provider from config.yaml ──────────────────────────────────────
model_str=""
config_yaml="$HOME/.hermes/config.yaml"
if [ -f "$config_yaml" ]; then
  read -r model provider < <("$PY" - "$config_yaml" <<'PY' 2>/dev/null
import sys
try:
    import yaml
except ImportError:
    print("? ?"); raise SystemExit
try:
    with open(sys.argv[1]) as f:
        d = yaml.safe_load(f)
except Exception:
    print("? ?"); raise SystemExit
m = (d or {}).get('model', {})
print(m.get('default', '?'), m.get('provider', '?'))
PY
)
  model_str=$(printf "${DIM}🤖$(trunc "$model" 20)@$provider${RESET}")
fi

# ── 4. Gateway status (from gateway_state.json, cached 30s) ────────────────────
gw_str=""
gw_json="$HOME/.hermes/gateway_state.json"
if [ -f "$gw_json" ]; then
  gw_cache="$HOME/.hermes/.gateway-status-cache"
  gw_age=999; [ -f "$gw_cache" ] && gw_age=$(($(date +%s) - $(date -r "$gw_cache" +%s 2>/dev/null || echo 0)))
  if [ "$gw_age" -ge 30 ]; then
    "$PY" - "$gw_json" > "$gw_cache.tmp" 2>/dev/null <<'PY' && mv "$gw_cache.tmp" "$gw_cache" 2>/dev/null
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
state = s.get('gateway_state', '?')
agents = s.get('active_agents', 0)
platforms = s.get('platforms', {})
connected = sum(1 for p in platforms.values() if p.get('state') == 'connected')
print(state, agents, connected)
PY
  fi
  if [ -f "$gw_cache" ]; then
    read -r gw_state gw_agents gw_conn < "$gw_cache" 2>/dev/null || true
    case "$gw_state" in
      running) gw_color="$G"; gw_icon="🌀" ;;
      *)       gw_color="$R"; gw_icon="🌀✗" ;;
    esac
    tag=""
    [ "${gw_agents:-0}" -gt 0 ] && tag="·${gw_agents}a"
    [ "${gw_conn:-0}" -gt 0 ]   && tag="${tag}·${gw_conn}⇄"
    gw_str=$(printf "${gw_color}${gw_icon}${tag}${RESET}")
  fi
fi

# ── 5. Serve backend status (from API, cached 30s) ────────────────────────────
serve_str=""
if command -v curl >/dev/null 2>&1; then
  srv_cache="$HOME/.hermes/.serve-status-cache"
  srv_age=999; [ -f "$srv_cache" ] && srv_age=$(($(date +%s) - $(date -r "$srv_cache" +%s 2>/dev/null || echo 0)))
  if [ "$srv_age" -ge 30 ]; then
    curl -sf --max-time 2 http://127.0.0.1:9119/api/status 2>/dev/null \
      | "$PY" -c "import sys,json; d=json.load(sys.stdin); print(d.get('active_sessions',0), d.get('gateway_state','?'))" 2>/dev/null \
      > "$srv_cache.tmp" 2>/dev/null && mv "$srv_cache.tmp" "$srv_cache" 2>/dev/null
  fi
  if [ -f "$srv_cache" ]; then
    read -r srv_sessions srv_gw < "$srv_cache" 2>/dev/null || true
    tag=""
    [ "${srv_sessions:-0}" -gt 0 ] && tag="·${srv_sessions}s"
    serve_str=$(printf "${G}🌐${tag}${RESET}")
  fi
fi

# ── 6. Gortex daemon status (cached 30s, bg-refreshed) ────────────────────────
# Identical logic to agents/statusline-command.sh gortex segment.
gortex_str=""
if [ -n "$cwd" ] && command -v gortex >/dev/null 2>&1; then
  gcache_dir="${HOME}/.hermes/gortex-cache"
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
      *)
        pshow=""; [ -n "$g_pct" ] && [ "$g_pct" != "-" ] && pshow="${g_pct}%"
        gortex_str=$(printf "${Y}🕸…${pshow}${RESET}") ;;
    esac
  fi
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

# ── Assemble ──────────────────────────────────────────────────────────────────
sep=$(printf "${DIM}│${RESET}")
out=""
for p in "$project_str" "$git_str" "$model_str" "$gw_str" "$serve_str" "$gortex_str"; do
  [ -z "$p" ] && continue
  if [ -z "$out" ]; then out="$p"; else out="${out} ${sep} ${p}"; fi
done

printf '%s\n' "$out"

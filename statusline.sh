#!/bin/bash
# Claude Code statusline
# 字段顺序: cwd (git) [wt] | model [effort] | ctx [bar] X% | 5h X% [reset] | wk X% [reset]
# 数值精度: 整数 (四舍五入). rate_limits 缺失时显示 — 占位符.
# 重置时间格式: 当天 "HH:MM"; 跨天 "M/D HH:MM" (24 小时制).

input=$(cat)

# === ANSI 颜色 (256 色暗色调色板, 减少视觉刺激) ===
GREEN=$'\033[38;5;65m'    # 苔藓绿 #5f875f
YELLOW=$'\033[38;5;136m'  # 暗琥珀 #af8700
RED=$'\033[38;5;131m'     # 砖红   #af5f5f
BLUE=$'\033[38;5;67m'     # 灰蓝   #5f87af
DIM=$'\033[2m'
RESET=$'\033[0m'

# === 一次性解析 JSON 字段 ===
parsed=$(echo "$input" | jq -r '
  [
    .cwd // "",
    .model.display_name // "",
    .context_window.used_percentage // "",
    .rate_limits.five_hour.used_percentage // "",
    .rate_limits.seven_day.used_percentage // "",
    .rate_limits.five_hour.resets_at // "",
    .rate_limits.seven_day.resets_at // "",
    .worktree.name // "",
    .worktree.path // "",
    .worktree.original_cwd // ""
  ] | @tsv
')
IFS=$'\t' read -r cwd model ctx_used five_hour seven_day five_reset seven_reset wt_name wt_path wt_orig <<< "$parsed"

# === 工作目录: $HOME 替换为 ~ ===
short_cwd="${cwd/#$HOME/~}"

# === 读 effort 档位 (默认值, 不反映 /effort 临时切换) ===
effort=""
if [ -f "$HOME/.claude/settings.json" ]; then
  effort=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null)
fi

# === Git 信息 (在 git 仓库时显示) ===
git_info=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  cd "$cwd" 2>/dev/null
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)

    flags=""
    status=$(git status --porcelain 2>/dev/null)
    if [ -n "$status" ]; then
      # 冲突
      if echo "$status" | grep -qE "^UU"; then
        flags="${flags} ${RED}!${RESET}"
      fi
      # 已暂存
      if echo "$status" | grep -qE "^[MADRC]"; then
        flags="${flags} ${YELLOW}+${RESET}"
      fi
      # 已修改未暂存 / 未跟踪
      if echo "$status" | grep -qE "^.[MADRC?]"; then
        flags="${flags} ${YELLOW}●${RESET}"
      fi
    fi

    # ahead / behind 远程
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    if [ -n "$upstream" ]; then
      counts=$(git rev-list --left-right --count "@{u}...HEAD" 2>/dev/null)
      if [ -n "$counts" ]; then
        behind=$(echo "$counts" | awk '{print $1}')
        ahead=$(echo "$counts" | awk '{print $2}')
        [ "$ahead" -gt 0 ] && flags="${flags} ${BLUE}⇡${ahead}${RESET}"
        [ "$behind" -gt 0 ] && flags="${flags} ${BLUE}⇣${behind}${RESET}"
      fi
    fi

    git_info=" (${branch}${flags})"
  fi
fi

# === Worktree 标记 (仅当处于 add 出来的 worktree 时, 统一显示 [wt]) ===
wt_info=""
if [ -n "$wt_name" ] && [ -n "$wt_path" ] && [ -n "$wt_orig" ] && [ "$wt_path" != "$wt_orig" ]; then
  wt_info=" ${DIM}[wt]${RESET}"
fi

# === 百分比 → 颜色 ===
color_for_pct() {
  local pct=$1
  if [ "$pct" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$pct" -ge 50 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"
  fi
}

# === Context 进度条 (10 格视觉, 数值整数精度) ===
ctx_segment=""
if [ -n "$ctx_used" ]; then
  ctx_int=$(printf "%.0f" "$ctx_used")
  filled=$(( ctx_int / 10 ))
  [ "$filled" -gt 10 ] && filled=10
  [ "$filled" -lt 0 ] && filled=0
  empty=$(( 10 - filled ))

  bar=""
  [ "$filled" -gt 0 ] && bar=$(printf "%${filled}s" | tr ' ' '█')
  [ "$empty" -gt 0 ] && bar="${bar}$(printf "%${empty}s" | tr ' ' '░')"

  c=$(color_for_pct "$ctx_int")
  ctx_segment="ctx ${c}[${bar}] ${ctx_int}%${RESET}"
fi

# === 重置时间格式化 (Unix epoch → "HH:MM" 当天 / "M/D HH:MM" 跨天) ===
fmt_reset_time() {
  local raw=$1
  [ -z "$raw" ] && return
  local target_int
  target_int=$(printf "%.0f" "$raw")
  local target_date
  target_date=$(date -r "$target_int" +%Y%m%d 2>/dev/null) || return
  local now_date
  now_date=$(date +%Y%m%d)
  if [ "$target_date" = "$now_date" ]; then
    date -r "$target_int" +"%H:%M"
  else
    date -r "$target_int" +"%-m/%-d %H:%M"
  fi
}

# === 5h / wk 百分比 + 重置时间 ===
# rate_limits 在新 session 首次 API 响应前不存在, 用 — 区分'未到达'与'真实 0%'
fmt_pct_segment() {
  local label=$1 raw=$2 reset_at=$3
  if [ -z "$raw" ]; then
    printf "%s %s—%s" "$label" "$DIM" "$RESET"
    return
  fi
  local val c
  val=$(printf "%.0f" "$raw")
  c=$(color_for_pct "$val")
  local time_part=""
  if [ -n "$reset_at" ]; then
    local t
    t=$(fmt_reset_time "$reset_at")
    [ -n "$t" ] && time_part=" ${DIM}[${t}]${RESET}"
  fi
  printf "%s %s%d%%%s%s" "$label" "$c" "$val" "$RESET" "$time_part"
}

five_segment=$(fmt_pct_segment "5h" "$five_hour" "$five_reset")
week_segment=$(fmt_pct_segment "wk" "$seven_day" "$seven_reset")

# === Model + Effort ===
model_segment="$model"
[ -n "$effort" ] && model_segment="${model} ${DIM}[${effort}]${RESET}"

# === 拼接输出 ===
output="${short_cwd}${git_info}${wt_info}  |  ${model_segment}"
[ -n "$ctx_segment" ]  && output="${output}  |  ${ctx_segment}"
[ -n "$five_segment" ] && output="${output}  |  ${five_segment}"
[ -n "$week_segment" ] && output="${output}  |  ${week_segment}"

printf "%s" "$output"

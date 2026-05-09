#!/bin/bash
# Claude Code statusline 一键安装脚本 (macOS)
# 安全策略: 不静默覆盖. 已存在则备份; settings.json 仅在未配置时写入.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/ZeyuSi-2099/claude-code-statusline/main"
TARGET_DIR="$HOME/.claude"
TARGET_SCRIPT="$TARGET_DIR/statusline.sh"
SETTINGS_FILE="$TARGET_DIR/settings.json"
EXPECTED_CMD="bash \$HOME/.claude/statusline.sh"

color_red()   { printf '\033[31m%s\033[0m' "$1"; }
color_green() { printf '\033[32m%s\033[0m' "$1"; }
color_dim()   { printf '\033[2m%s\033[0m' "$1"; }

info()  { printf '%s %s\n' "$(color_dim '[info]')" "$1"; }
ok()    { printf '%s %s\n' "$(color_green '[ ok ]')" "$1"; }
warn()  { printf '%s %s\n' "$(color_red '[warn]')" "$1"; }
fail()  { printf '%s %s\n' "$(color_red '[err ]')" "$1" >&2; exit 1; }

# === 1. 依赖检查 ===
info "检查依赖..."
for cmd in bash jq git curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "缺少依赖: $cmd. 请先安装 (brew install $cmd) 后重试."
  fi
done
ok "依赖齐全 (bash, jq, git, curl)"

# === 2. 确保目录存在 ===
mkdir -p "$TARGET_DIR"

# === 3. 备份现有 statusline.sh ===
if [ -f "$TARGET_SCRIPT" ]; then
  ts=$(date +%Y%m%d-%H%M%S)
  backup="$TARGET_SCRIPT.bak.$ts"
  cp "$TARGET_SCRIPT" "$backup"
  ok "已备份现有 statusline.sh → $backup"
fi

# === 4. 下载新脚本 ===
info "下载 statusline.sh ..."
tmp=$(mktemp)
if ! curl -fsSL "$REPO_RAW/statusline.sh" -o "$tmp"; then
  rm -f "$tmp"
  fail "下载失败. 检查网络或仓库地址: $REPO_RAW/statusline.sh"
fi
mv "$tmp" "$TARGET_SCRIPT"
chmod +x "$TARGET_SCRIPT"
ok "已写入 $TARGET_SCRIPT"

# === 5. 配置 settings.json ===
if [ ! -f "$SETTINGS_FILE" ]; then
  info "settings.json 不存在, 创建新文件..."
  printf '{\n  "statusLine": {\n    "type": "command",\n    "command": "%s"\n  }\n}\n' "$EXPECTED_CMD" > "$SETTINGS_FILE"
  ok "已创建 settings.json 并配置 statusLine"
else
  current=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null || echo "")
  if [ -z "$current" ]; then
    # 未配置 → 用 jq 写入
    tmp_settings=$(mktemp)
    jq --arg cmd "$EXPECTED_CMD" '.statusLine = {type: "command", command: $cmd}' "$SETTINGS_FILE" > "$tmp_settings"
    mv "$tmp_settings" "$SETTINGS_FILE"
    ok "已在 settings.json 中写入 statusLine 配置"
  elif [ "$current" = "$EXPECTED_CMD" ]; then
    ok "settings.json 中 statusLine 已正确配置, 跳过"
  else
    warn "settings.json 中 statusLine.command 已被设置为:"
    printf '       %s\n' "$current"
    warn "为避免破坏你的自定义配置, 未自动覆盖."
    warn "如需启用本仓库的 statusline, 请手动改为:"
    printf '       %s\n' "$EXPECTED_CMD"
  fi
fi

# === 6. 完成提示 ===
printf '\n'
ok "安装完成. 重启 Claude Code 后状态栏即可生效."

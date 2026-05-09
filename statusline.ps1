# Claude Code statusline (Windows / PowerShell)
# 字段顺序: cwd (git) [wt] | model [effort] | ctx [bar] X% | 5h X% [reset] | wk X% [reset]
# 数值精度: 整数 (四舍五入). rate_limits 缺失时显示 — 占位符.
# 重置时间格式: 当天 "HH:mm"; 跨天 "M/d HH:mm" (24 小时制).

$ErrorActionPreference = 'SilentlyContinue'

# === stdin JSON: 从原始字节流按 UTF-8 解码 ===
# 绕过 [Console]::In 启动时绑定的系统 ANSI 代码页 (中文 Windows 默认 CP936),
# 否则 cwd 等含非 ASCII 字符的字段会被错误解码成乱码.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

$stdin  = [Console]::OpenStandardInput()
$reader = [System.IO.StreamReader]::new($stdin, $utf8NoBom)
$raw    = $reader.ReadToEnd()
if (-not $raw) { return }
try { $d = $raw | ConvertFrom-Json } catch { return }

# === ANSI 颜色 (256 色暗色调色板, 减少视觉刺激) ===
$ESC    = [char]27
$GREEN  = "$ESC[38;5;65m"
$YELLOW = "$ESC[38;5;136m"
$RED    = "$ESC[38;5;131m"
$BLUE   = "$ESC[38;5;67m"
$DIM    = "$ESC[2m"
$RST    = "$ESC[0m"

# === 字段提取 ===
function Get-Prop($obj, $path) {
  $cur = $obj
  foreach ($p in $path -split '\.') {
    if ($null -eq $cur) { return $null }
    $cur = $cur.$p
  }
  return $cur
}

$cwd        = [string](Get-Prop $d 'cwd')
$model      = [string](Get-Prop $d 'model.display_name')
$ctxUsed    = Get-Prop $d 'context_window.used_percentage'
$fiveHour   = Get-Prop $d 'rate_limits.five_hour.used_percentage'
$sevenDay   = Get-Prop $d 'rate_limits.seven_day.used_percentage'
$fiveReset  = Get-Prop $d 'rate_limits.five_hour.resets_at'
$sevenReset = Get-Prop $d 'rate_limits.seven_day.resets_at'
$wtName     = [string](Get-Prop $d 'worktree.name')
$wtPath     = [string](Get-Prop $d 'worktree.path')
$wtOrig     = [string](Get-Prop $d 'worktree.original_cwd')

# === 工作目录: $HOME 替换为 ~ (规范化斜杠以兼容 / 与 \) ===
function Normalize-Path([string]$p) {
  if (-not $p) { return '' }
  return ($p -replace '/', '\').TrimEnd('\')
}
$shortCwd = $cwd
$homeDir = $env:USERPROFILE
if ($homeDir -and $cwd) {
  $nCwd  = Normalize-Path $cwd
  $nHome = Normalize-Path $homeDir
  if ($nCwd.Length -ge $nHome.Length -and
      $nCwd.Substring(0, $nHome.Length).Equals($nHome, [StringComparison]::OrdinalIgnoreCase)) {
    $rest = $nCwd.Substring($nHome.Length)
    $shortCwd = '~' + $rest
  }
}

# === 读 effort 档位 (默认值, 不反映 /effort 临时切换) ===
$effort = ''
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path -LiteralPath $settingsPath) {
  try {
    $s = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $effort = [string]$s.effortLevel
  } catch { $effort = '' }
}

# === Git 信息 (在 git 仓库时显示) ===
$gitInfo = ''
if ($cwd -and (Test-Path -LiteralPath $cwd)) {
  Push-Location -LiteralPath $cwd
  try {
    $isRepo = git rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0 -and $isRepo -eq 'true') {
      $branch = git symbolic-ref --short HEAD 2>$null
      if (-not $branch) { $branch = git rev-parse --short HEAD 2>$null }

      $flags = ''
      $status = git status --porcelain 2>$null
      if ($status) {
        $statusText = ($status -join "`n")
        # 冲突
        if ($statusText -match '(?m)^UU') {
          $flags = "$flags ${RED}!${RST}"
        }
        # 已暂存
        if ($statusText -match '(?m)^[MADRC]') {
          $flags = "$flags ${YELLOW}+${RST}"
        }
        # 已修改未暂存 / 未跟踪
        if ($statusText -match '(?m)^.[MADRC?]') {
          $flags = "$flags ${YELLOW}$([char]0x25CF)${RST}"
        }
      }

      # ahead / behind 远程
      $upstream = git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
      if ($LASTEXITCODE -eq 0 -and $upstream) {
        $counts = git rev-list --left-right --count '@{u}...HEAD' 2>$null
        if ($counts) {
          $parts = ($counts -split '\s+') | Where-Object { $_ -ne '' }
          if ($parts.Count -ge 2) {
            $behind = [int]$parts[0]
            $ahead  = [int]$parts[1]
            if ($ahead  -gt 0) { $flags = "$flags ${BLUE}$([char]0x21E1)$ahead${RST}" }
            if ($behind -gt 0) { $flags = "$flags ${BLUE}$([char]0x21E3)$behind${RST}" }
          }
        }
      }

      $gitInfo = " ($branch$flags)"
    }
  } finally {
    Pop-Location
  }
}

# === Worktree 标记 (仅当处于 add 出来的 worktree 时, 统一显示 [wt]) ===
$wtInfo = ''
if ($wtName -and $wtPath -and $wtOrig -and ($wtPath -ne $wtOrig)) {
  $wtInfo = " ${DIM}[wt]${RST}"
}

# === 百分比 → 颜色 ===
function Get-PctColor([int]$pct) {
  if ($pct -ge 80) { return $RED }
  elseif ($pct -ge 50) { return $YELLOW }
  else { return $GREEN }
}

# === Context 进度条 (10 格视觉, 数值整数精度) ===
$ctxSeg = ''
if ($null -ne $ctxUsed -and "$ctxUsed" -ne '') {
  $ctxInt = [int][Math]::Round([double]$ctxUsed)
  $filled = [int][Math]::Floor($ctxInt / 10)
  if ($filled -gt 10) { $filled = 10 }
  if ($filled -lt 0)  { $filled = 0 }
  $empty = 10 - $filled
  $bar = ''
  if ($filled -gt 0) { $bar  = [string]::new([char]0x2588, $filled) }
  if ($empty  -gt 0) { $bar += [string]::new([char]0x2591, $empty) }
  $c = Get-PctColor $ctxInt
  $ctxSeg = "ctx $c[$bar] $ctxInt%$RST"
}

# === 重置时间格式化 (Unix epoch → "HH:mm" 当天 / "M/d HH:mm" 跨天) ===
function Format-ResetTime($raw) {
  if ($null -eq $raw -or "$raw" -eq '') { return '' }
  try {
    $epoch = [long][Math]::Round([double]$raw)
    $dt = [DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime
    $now = Get-Date
    if ($dt.Date -eq $now.Date) {
      return $dt.ToString('HH:mm')
    } else {
      return $dt.ToString('M/d HH:mm')
    }
  } catch { return '' }
}

# === 5h / wk 百分比 + 重置时间 ===
# rate_limits 在新 session 首次 API 响应前不存在, 用 — 区分'未到达'与'真实 0%'
function Format-PctSegment([string]$label, $raw, $resetAt) {
  if ($null -eq $raw -or "$raw" -eq '') {
    return "$label $DIM$([char]0x2014)$RST"
  }
  $val = [int][Math]::Round([double]$raw)
  $c = Get-PctColor $val
  $timePart = ''
  if ($null -ne $resetAt -and "$resetAt" -ne '') {
    $t = Format-ResetTime $resetAt
    if ($t) { $timePart = " $DIM[$t]$RST" }
  }
  return "$label $c$val%$RST$timePart"
}

$fiveSeg = Format-PctSegment '5h' $fiveHour  $fiveReset
$weekSeg = Format-PctSegment 'wk' $sevenDay  $sevenReset

# === Model + Effort ===
$modelSeg = $model
if ($effort) { $modelSeg = "$model $DIM[$effort]$RST" }

# === 拼接输出 ===
$output = "$shortCwd$gitInfo$wtInfo  |  $modelSeg"
if ($ctxSeg)  { $output += "  |  $ctxSeg" }
if ($fiveSeg) { $output += "  |  $fiveSeg" }
if ($weekSeg) { $output += "  |  $weekSeg" }

[Console]::Out.Write($output)

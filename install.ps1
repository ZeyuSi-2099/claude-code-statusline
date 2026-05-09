# Claude Code statusline 一键安装脚本 (Windows / PowerShell)
# 安全策略: 不静默覆盖. 已存在则备份; settings.json 仅在未配置时写入.

$ErrorActionPreference = 'Stop'

$RepoRaw      = 'https://raw.githubusercontent.com/ZeyuSi-2099/claude-code-statusline/main'
$TargetDir    = Join-Path $env:USERPROFILE '.claude'
$TargetScript = Join-Path $TargetDir 'statusline.ps1'
$SettingsFile = Join-Path $TargetDir 'settings.json'
$ExpectedCmd  = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $TargetScript + '"'

function Write-Info([string]$m) { Write-Host '[info] ' -NoNewline -ForegroundColor DarkGray; Write-Host $m }
function Write-OK  ([string]$m) { Write-Host '[ ok ] ' -NoNewline -ForegroundColor Green;     Write-Host $m }
function Write-Warn2([string]$m) { Write-Host '[warn] ' -NoNewline -ForegroundColor Yellow;    Write-Host $m }
function Stop-Fail ([string]$m) { Write-Host '[err ] ' -NoNewline -ForegroundColor Red;       Write-Host $m; exit 1 }

# === 1. 依赖检查 ===
Write-Info '检查依赖...'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Stop-Fail '缺少依赖: git. 请先安装 Git for Windows (https://git-scm.com/download/win) 后重试.'
}
Write-OK '依赖齐全 (git, PowerShell)'

# === 2. 确保目录存在 ===
New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

# === 3. 备份现有 statusline.ps1 ===
if (Test-Path -LiteralPath $TargetScript) {
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = "$TargetScript.bak.$ts"
  Copy-Item -LiteralPath $TargetScript -Destination $backup -Force
  Write-OK "已备份现有 statusline.ps1 → $backup"
}

# === 4. 下载新脚本 ===
Write-Info '下载 statusline.ps1 ...'
$tmp = [System.IO.Path]::GetTempFileName()
try {
  Invoke-WebRequest -Uri "$RepoRaw/statusline.ps1" -OutFile $tmp -UseBasicParsing
} catch {
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  Stop-Fail "下载失败. 检查网络或仓库地址: $RepoRaw/statusline.ps1"
}
Move-Item -LiteralPath $tmp -Destination $TargetScript -Force
Write-OK "已写入 $TargetScript"

# === 5. 配置 settings.json ===
function Write-JsonNoBom([string]$path, [string]$json) {
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
}

if (-not (Test-Path -LiteralPath $SettingsFile)) {
  Write-Info 'settings.json 不存在, 创建新文件...'
  $obj = [ordered]@{
    statusLine = [ordered]@{
      type    = 'command'
      command = $ExpectedCmd
    }
  }
  Write-JsonNoBom $SettingsFile ($obj | ConvertTo-Json -Depth 10)
  Write-OK '已创建 settings.json 并配置 statusLine'
} else {
  $current = ''
  try {
    $settings = Get-Content -LiteralPath $SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($settings -and $settings.statusLine -and $settings.statusLine.command) {
      $current = [string]$settings.statusLine.command
    }
  } catch {
    $settings = $null
  }

  if (-not $current) {
    if ($null -eq $settings) { $settings = [pscustomobject]@{} }
    $newStatus = [pscustomobject]@{ type = 'command'; command = $ExpectedCmd }
    if ($settings.PSObject.Properties.Name -contains 'statusLine') {
      $settings.statusLine = $newStatus
    } else {
      $settings | Add-Member -NotePropertyName statusLine -NotePropertyValue $newStatus -Force
    }
    Write-JsonNoBom $SettingsFile ($settings | ConvertTo-Json -Depth 10)
    Write-OK '已在 settings.json 中写入 statusLine 配置'
  } elseif ($current -eq $ExpectedCmd) {
    Write-OK 'settings.json 中 statusLine 已正确配置, 跳过'
  } else {
    Write-Warn2 'settings.json 中 statusLine.command 已被设置为:'
    Write-Host "       $current"
    Write-Warn2 '为避免破坏你的自定义配置, 未自动覆盖.'
    Write-Warn2 '如需启用本仓库的 statusline, 请手动改为:'
    Write-Host "       $ExpectedCmd"
  }
}

# === 6. 完成提示 ===
Write-Host ''
Write-OK '安装完成. 重启 Claude Code 后状态栏即可生效.'

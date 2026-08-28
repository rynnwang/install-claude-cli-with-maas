<#
  claude-maas.ps1
  One-click installer & manager for Claude Code CLI + a MaaS (Anthropic-compatible)
  endpoint on Windows, with an interactive menu inspired by fscarmen's sing-box script.

  First run (via `irm ... | iex`) shows the menu and can install itself as the
  `claude-maas` command (PowerShell function + .cmd shim) so you can re-open this
  menu any time.

  Repo:    https://github.com/rynnwang/install-claude-cli-with-maas
  License: MIT

  Works on Windows PowerShell 5.1 and PowerShell 7+.
#>

$ErrorActionPreference = 'Stop'
$script:Version = '1.0.0'

# --------------------------------------------------------------------------- #
# Paths
# --------------------------------------------------------------------------- #
$script:ConfigDir       = Join-Path $HOME '.config\claude-maas'
$script:ConfigFile      = Join-Path $script:ConfigDir 'config.env'
$script:SelfPs1         = Join-Path $script:ConfigDir 'claude-maas.ps1'
$script:SelfCmd         = Join-Path $script:ConfigDir 'claude-maas.cmd'
$script:ClaudeDir       = Join-Path $HOME '.claude'
$script:ClaudeSettings  = Join-Path $script:ClaudeDir 'settings.json'
$script:RawUrl          = 'https://raw.githubusercontent.com/rynnwang/install-claude-cli-with-maas/main/claude-maas.ps1'

$script:ProfileMarkBegin = '# >>> claude-maas >>>'
$script:ProfileMarkEnd   = '# <<< claude-maas <<<'

# Managed environment keys. Only these are ever written or removed by this tool.
$script:ManagedKeys = @(
  'ANTHROPIC_BASE_URL'
  'ANTHROPIC_AUTH_TOKEN'
  'ANTHROPIC_API_KEY'
  'ANTHROPIC_MODEL'
  'ANTHROPIC_SMALL_FAST_MODEL'
  'ANTHROPIC_DEFAULT_OPUS_MODEL'
  'ANTHROPIC_DEFAULT_SONNET_MODEL'
  'ANTHROPIC_DEFAULT_HAIKU_MODEL'
  'API_TIMEOUT_MS'
  'CLAUDE_CODE_MAX_OUTPUT_TOKENS'
)
$script:SecretKeys = @('ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY')

# --------------------------------------------------------------------------- #
# Output helpers
# --------------------------------------------------------------------------- #
function Write-Info { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err2 { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red }
function Write-Hr   { Write-Host ('-' * 60) -ForegroundColor DarkGray }
function Pause-Menu { Read-Host "`n按回车返回菜单" | Out-Null }

function Read-WithDefault {
  param([string]$Prompt, [string]$Default = '')
  $suffix = if ($Default) { " [$Default]" } else { '' }
  $v = Read-Host ("{0}{1}" -f $Prompt, $suffix)
  if ([string]::IsNullOrEmpty($v)) { return $Default }
  return $v
}

function Read-Secret {
  param([string]$Prompt, [string]$Current = '')
  $hint = ''
  if ($Current) {
    if ($Current.Length -le 8) { $hint = ' (已有值，直接回车保留)' }
    else { $hint = " (已有 $($Current.Substring(0,4))…$($Current.Substring($Current.Length-4))，回车保留)" }
  }
  $sec = Read-Host ("{0}{1}" -f $Prompt, $hint) -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  if ([string]::IsNullOrEmpty($plain)) { return $Current }
  return $plain
}

function Confirm-YN {
  param([string]$Prompt, [string]$Default = 'N')
  $hint = if ($Default -eq 'Y') { '[Y/n]' } else { '[y/N]' }
  $v = Read-Host "$Prompt $hint"
  if ([string]::IsNullOrEmpty($v)) { $v = $Default }
  return ($v -match '^(y|yes)$')
}

function Mask-Value {
  param([string]$v)
  if ([string]::IsNullOrEmpty($v)) { return '(未设置)' }
  if ($v.Length -le 10) { return '***' }
  return "$($v.Substring(0,4))…$($v.Substring($v.Length-4))"
}

# Write text as UTF-8 WITHOUT BOM. Windows PowerShell 5.1's -Encoding utf8 emits a
# BOM, which breaks Node's JSON.parse when Claude Code reads its own settings.json.
function Write-TextNoBom {
  param([string]$Path, [string[]]$Lines)
  $text = ($Lines -join "`n") + "`n"
  [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# --------------------------------------------------------------------------- #
# config.env read / write  (KEY='value' lines, single-quoted)
# --------------------------------------------------------------------------- #
function Get-ConfigMap {
  $map = @{}
  if (Test-Path $script:ConfigFile) {
    foreach ($line in Get-Content -LiteralPath $script:ConfigFile) {
      if ($line -match "^\s*#") { continue }
      if ($line -match "^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$") {
        $k = $Matches[1]; $val = $Matches[2].Trim()
        if ($val.StartsWith("'") -and $val.EndsWith("'") -and $val.Length -ge 2) {
          $val = $val.Substring(1, $val.Length - 2).Replace("'\''", "'")
        }
        $map[$k] = $val
      }
    }
  }
  return $map
}

function Write-ConfigMap {
  param([hashtable]$Map)
  New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
  $lines = @()
  $lines += "# Managed by claude-maas — do not edit by hand; run: claude-maas"
  $lines += "# " + (Get-Date -Format o)
  foreach ($k in $script:ManagedKeys) {
    $v = [string]$Map[$k]
    if (-not [string]::IsNullOrEmpty($v)) {
      $esc = $v.Replace("'", "'\''")
      $lines += ("{0}='{1}'" -f $k, $esc)
    }
  }
  Write-TextNoBom -Path $script:ConfigFile -Lines $lines
  Write-Ok "已写入 $script:ConfigFile"
}

# --------------------------------------------------------------------------- #
# Claude Code CLI install / update
# --------------------------------------------------------------------------- #
function Get-ClaudeCmd {
  $c = Get-Command claude -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}

function Get-ClaudeVersion {
  $b = Get-ClaudeCmd
  if ($b) { try { return (& $b --version 2>$null | Select-Object -First 1) } catch { return $null } }
  return $null
}

function Install-ClaudeCode {
  Write-Hr
  $existing = Get-ClaudeCmd
  if ($existing) {
    Write-Ok "已检测到 Claude Code: $existing"
    Write-Info "当前版本: $(Get-ClaudeVersion)"
    if (-not (Confirm-YN "重新安装 / 更新到最新版?" 'N')) { Pause-Menu; return }
  }

  Write-Host ''
  Write-Host "选择安装方式:"
  Write-Host "  1) 官方原生安装脚本 (推荐, 无需 Node)"
  Write-Host "  2) npm 全局安装 (@anthropic-ai/claude-code, 需要 Node >= 18)"
  Write-Host "  3) 仅运行 'claude update' (若已安装)"
  Write-Host "  0) 返回"
  $m = Read-WithDefault '输入序号' '1'
  switch ($m) {
    '1' {
      Write-Info "正在执行官方安装脚本: https://claude.ai/install.ps1"
      try {
        $sb = [scriptblock]::Create((Invoke-RestMethod -Uri 'https://claude.ai/install.ps1'))
        & $sb
      } catch { Write-Err2 "安装脚本执行失败: $($_.Exception.Message)" }
    }
    '2' {
      if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Err2 "未找到 npm，请先安装 Node.js (https://nodejs.org)"; Pause-Menu; return
      }
      Write-Info "正在执行: npm install -g @anthropic-ai/claude-code"
      & npm install -g '@anthropic-ai/claude-code'
    }
    '3' {
      if (-not $existing) { Write-Err2 "尚未安装 Claude Code"; Pause-Menu; return }
      try { & $existing update } catch { Write-Warn2 "claude update 返回错误" }
    }
    '0' { return }
    default { Write-Err2 "无效选项"; Pause-Menu; return }
  }

  $b = Get-ClaudeCmd
  if ($b) {
    Write-Ok "Claude Code 就绪: $b ($(Get-ClaudeVersion))"
  } else {
    Write-Warn2 "安装已结束，但当前会话未找到 'claude'。通常是 PATH 未刷新——请新开一个 PowerShell 窗口。"
  }
  Pause-Menu
}

# --------------------------------------------------------------------------- #
# settings.json  (~/.claude/settings.json  ->  .env block)
# --------------------------------------------------------------------------- #
function Read-SettingsEnv {
  if (-not (Test-Path $script:ClaudeSettings)) { return @{} }
  try {
    $json = Get-Content -LiteralPath $script:ClaudeSettings -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
    $obj = $json | ConvertFrom-Json
  } catch {
    Write-Warn2 "settings.json 解析失败: $($_.Exception.Message)"
    return $null
  }
  $map = @{}
  if ($obj.PSObject.Properties.Name -contains 'env' -and $obj.env) {
    foreach ($p in $obj.env.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
  }
  return $map
}

function Save-SettingsEnv {
  param([hashtable]$Map)   # full desired env map (empty values are dropped)

  New-Item -ItemType Directory -Force -Path $script:ClaudeDir | Out-Null
  $obj = $null
  if (Test-Path $script:ClaudeSettings) {
    try {
      $raw = Get-Content -LiteralPath $script:ClaudeSettings -Raw -Encoding utf8
      $obj = if ([string]::IsNullOrWhiteSpace($raw)) { [pscustomobject]@{} } else { $raw | ConvertFrom-Json }
    } catch {
      Write-Err2 "$script:ClaudeSettings 不是合法 JSON，已跳过以免损坏。请手动修复后重试。"
      return $false
    }
    Copy-Item -LiteralPath $script:ClaudeSettings -Destination "$script:ClaudeSettings.claude-maas.bak" -Force
  } else {
    $obj = [pscustomobject]@{}
  }
  if ($obj -isnot [pscustomobject]) {
    Write-Err2 "settings.json 顶层不是对象，已跳过。"
    return $false
  }

  # Start from existing env (preserve non-managed keys), then apply managed ones.
  $env2 = [ordered]@{}
  if ($obj.PSObject.Properties.Name -contains 'env' -and $obj.env) {
    foreach ($p in $obj.env.PSObject.Properties) { $env2[$p.Name] = $p.Value }
  }
  foreach ($k in $script:ManagedKeys) {
    $v = [string]$Map[$k]
    if ([string]::IsNullOrEmpty($v)) { if ($env2.Contains($k)) { $env2.Remove($k) } }
    else { $env2[$k] = $v }
  }

  if ($env2.Count -gt 0) {
    $obj | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]$env2) -Force
  } elseif ($obj.PSObject.Properties.Name -contains 'env') {
    $obj.PSObject.Properties.Remove('env')
  }

  $json = $obj | ConvertTo-Json -Depth 30
  Write-TextNoBom -Path $script:ClaudeSettings -Lines @($json)
  Write-Ok "已更新 $script:ClaudeSettings  (备份: settings.json.claude-maas.bak)"
  return $true
}

# --------------------------------------------------------------------------- #
# User environment variables (persistent, 'User' scope)
# --------------------------------------------------------------------------- #
function Apply-UserEnv {
  param([hashtable]$Map)
  foreach ($k in $script:ManagedKeys) {
    $v = [string]$Map[$k]
    if ([string]::IsNullOrEmpty($v)) {
      [Environment]::SetEnvironmentVariable($k, $null, 'User')
      Set-Item -Path "Env:$k" -Value '' -ErrorAction SilentlyContinue
      Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue
    } else {
      [Environment]::SetEnvironmentVariable($k, $v, 'User')
      Set-Item -Path "Env:$k" -Value $v   # also this session
    }
  }
  Write-Ok "已写入用户级环境变量 (HKCU\Environment)。"
  Write-Warn2 "已开的程序 / 终端需要重启才能读到新值；本 PowerShell 会话已即时更新。"
}

# --------------------------------------------------------------------------- #
# MaaS configuration flow
# --------------------------------------------------------------------------- #
function Configure-Maas {
  Write-Hr
  Write-Host "配置 MaaS 连接" -ForegroundColor White
  Write-Host "留空表示不设置 / 清除该项。Token 输入时不回显。" -ForegroundColor DarkGray
  Write-Host ''

  $cur = Get-ConfigMap
  $sj  = Read-SettingsEnv
  if ($sj) { foreach ($k in $sj.Keys) { if (-not $cur.ContainsKey($k) -or -not $cur[$k]) { $cur[$k] = $sj[$k] } } }

  $base = Read-WithDefault 'ANTHROPIC_BASE_URL  (MaaS 接口地址, 形如 https://your-maas.example.com/api)' ([string]$cur['ANTHROPIC_BASE_URL'])
  $base = $base.TrimEnd('/')

  Write-Host ''
  Write-Host "鉴权方式 (取决于你的 MaaS 平台):"
  Write-Host "  1) Bearer Token  -> ANTHROPIC_AUTH_TOKEN (最常见)"
  Write-Host "  2) API Key       -> ANTHROPIC_API_KEY (x-api-key 头)"
  $am = Read-WithDefault '输入序号' '1'
  $token = ''; $apikey = ''
  if ($am -eq '2') {
    $apikey = Read-Secret 'ANTHROPIC_API_KEY' ([string]$cur['ANTHROPIC_API_KEY'])
  } else {
    $token = Read-Secret 'ANTHROPIC_AUTH_TOKEN' ([string]$cur['ANTHROPIC_AUTH_TOKEN'])
  }

  Write-Host ''
  Write-Host "模型名称留空则使用 Claude Code 默认值；具体可用模型以 MaaS 平台文档为准。" -ForegroundColor DarkGray
  $model = Read-WithDefault 'ANTHROPIC_MODEL            (主模型, 可留空)' ([string]$cur['ANTHROPIC_MODEL'])
  $small = Read-WithDefault 'ANTHROPIC_SMALL_FAST_MODEL (轻量/快速模型, 可留空)' ([string]$cur['ANTHROPIC_SMALL_FAST_MODEL'])

  $map = @{}
  foreach ($k in $script:ManagedKeys) { $map[$k] = [string]$cur[$k] }
  $map['ANTHROPIC_BASE_URL']         = $base
  $map['ANTHROPIC_AUTH_TOKEN']       = $token
  $map['ANTHROPIC_API_KEY']          = $apikey
  $map['ANTHROPIC_MODEL']            = $model
  $map['ANTHROPIC_SMALL_FAST_MODEL'] = $small

  Write-Host ''
  Write-Hr
  Write-Host "写入方式:"
  Write-Host "  1) Claude Code settings.json  (%USERPROFILE%\.claude\settings.json 的 env 块)"
  Write-Host "     跨平台一致、只影响 Claude Code、不动系统环境变量 —— 推荐" -ForegroundColor Green
  Write-Host "  2) 用户级系统环境变量 (HKCU\Environment / setx 等效)"
  Write-Host "     对所有读取 ANTHROPIC_* 的程序生效；已开窗口需重启"
  Write-Host "  3) 两者都写"
  Write-Host "  0) 取消"
  $w = Read-WithDefault '输入序号' '1'

  switch ($w) {
    '1' { [void](Save-SettingsEnv $map) }
    '2' { Write-ConfigMap $map; Apply-UserEnv $map }
    '3' { [void](Save-SettingsEnv $map); Write-ConfigMap $map; Apply-UserEnv $map }
    default { Write-Warn2 "已取消，未写入任何配置"; Pause-Menu; return }
  }

  Write-Host ''
  Write-Ok "配置完成。新开一个 PowerShell / CMD 窗口后运行 'claude' 即可。"
  Pause-Menu
}

# --------------------------------------------------------------------------- #
# Show config
# --------------------------------------------------------------------------- #
function Show-Config {
  Write-Hr
  Write-Host "当前配置" -ForegroundColor White
  Write-Host ''

  Write-Host "1) Claude Code settings.json  ($script:ClaudeSettings)" -ForegroundColor Cyan
  $sj = Read-SettingsEnv
  if ($null -eq $sj) { Write-Host "   (解析失败)" -ForegroundColor DarkGray }
  elseif ($sj.Count -eq 0) { Write-Host "   (无受管键 / 文件不存在)" -ForegroundColor DarkGray }
  else {
    foreach ($k in $script:ManagedKeys) {
      if ($sj.ContainsKey($k) -and $sj[$k]) {
        $val = if ($script:SecretKeys -contains $k) { Mask-Value $sj[$k] } else { $sj[$k] }
        "   {0,-28} = {1}" -f $k, $val | Write-Host
      }
    }
  }

  Write-Host ''
  Write-Host "2) 受管环境变量文件  ($script:ConfigFile)" -ForegroundColor Cyan
  $cf = Get-ConfigMap
  if ($cf.Count -eq 0) { Write-Host "   (文件不存在)" -ForegroundColor DarkGray }
  else {
    foreach ($k in $script:ManagedKeys) {
      if ($cf.ContainsKey($k) -and $cf[$k]) {
        $val = if ($script:SecretKeys -contains $k) { Mask-Value $cf[$k] } else { $cf[$k] }
        "   {0,-28} = {1}" -f $k, $val | Write-Host
      }
    }
  }

  Write-Host ''
  Write-Host "3) 用户级系统环境变量 (HKCU\Environment)" -ForegroundColor Cyan
  $any = $false
  foreach ($k in $script:ManagedKeys) {
    $v = [Environment]::GetEnvironmentVariable($k, 'User')
    if ($v) {
      $any = $true
      $val = if ($script:SecretKeys -contains $k) { Mask-Value $v } else { $v }
      "   {0,-28} = {1}" -f $k, $val | Write-Host
    }
  }
  if (-not $any) { Write-Host "   (无)" -ForegroundColor DarkGray }

  Write-Host ''
  Write-Host "4) 当前会话已生效的值" -ForegroundColor Cyan
  $any = $false
  foreach ($k in @('ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_MODEL','ANTHROPIC_SMALL_FAST_MODEL')) {
    $v = [Environment]::GetEnvironmentVariable($k)
    if ($v) {
      $any = $true
      $val = if ($script:SecretKeys -contains $k) { Mask-Value $v } else { $v }
      "   {0,-28} = {1}" -f $k, $val | Write-Host
    }
  }
  if (-not $any) { Write-Host "   (无 —— 需重开窗口，或本会话未走受管配置)" -ForegroundColor DarkGray }

  Write-Host ''
  $b = Get-ClaudeCmd
  if ($b) { Write-Host "Claude Code: $b  ($(Get-ClaudeVersion))" -ForegroundColor Cyan }
  else    { Write-Host "Claude Code: 未安装 / 不在 PATH" -ForegroundColor DarkGray }
  Pause-Menu
}

# --------------------------------------------------------------------------- #
# Test connection
# --------------------------------------------------------------------------- #
function Resolve-Effective {
  param([string]$Key)
  $v = [Environment]::GetEnvironmentVariable($Key)                # session
  if ($v) { return $v }
  $sj = Read-SettingsEnv
  if ($sj -and $sj.ContainsKey($Key) -and $sj[$Key]) { return [string]$sj[$Key] }
  $cf = Get-ConfigMap
  if ($cf.ContainsKey($Key)) { return [string]$cf[$Key] }
  return ''
}

function Invoke-MaasTest {
  Write-Hr
  $base   = Resolve-Effective 'ANTHROPIC_BASE_URL'
  $token  = Resolve-Effective 'ANTHROPIC_AUTH_TOKEN'
  $apikey = Resolve-Effective 'ANTHROPIC_API_KEY'
  $model  = Resolve-Effective 'ANTHROPIC_SMALL_FAST_MODEL'
  if (-not $model) { $model = Resolve-Effective 'ANTHROPIC_MODEL' }
  if (-not $model) { $model = 'claude-3-5-haiku-20241022' }

  if (-not $base) { Write-Err2 "未找到 ANTHROPIC_BASE_URL，请先运行「配置 MaaS 连接」"; Pause-Menu; return }

  $authDesc = if ($token) { 'Bearer ANTHROPIC_AUTH_TOKEN' } elseif ($apikey) { 'x-api-key ANTHROPIC_API_KEY' } else { '(无, 可能失败)' }
  Write-Info "Base URL : $base"
  Write-Info "Model    : $model"
  Write-Info "Auth     : $authDesc"
  Write-Host ''

  $url = "$base/v1/messages"
  $headers = @{ 'content-type' = 'application/json'; 'anthropic-version' = '2023-06-01' }
  if ($token)  { $headers['authorization'] = "Bearer $token" }
  if ($apikey) { $headers['x-api-key'] = $apikey }
  $bodyObj = @{ model = $model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'ping' }) }
  $body = $bodyObj | ConvertTo-Json -Depth 5 -Compress

  Write-Host "POST $url"
  try {
    $resp = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 30 -UseBasicParsing
    Write-Ok "HTTP $([int]$resp.StatusCode) —— 连接与鉴权正常 ✅"
  } catch [System.Net.WebException] {
    $r = $_.Exception.Response
    if ($r) {
      $code = [int]$r.StatusCode
      $txt = ''
      try {
        $sr = New-Object IO.StreamReader($r.GetResponseStream())
        $txt = $sr.ReadToEnd(); $sr.Close()
      } catch {}
      switch ($code) {
        400 { Write-Warn2 "HTTP 400 —— 已连通、鉴权可能通过；多为模型名不被接受。"; if ($txt) { Write-Host ($txt.Substring(0,[Math]::Min(500,$txt.Length))) } }
        401 { Write-Err2 "HTTP 401 —— 鉴权失败，检查 Token / API Key。"; if ($txt) { Write-Host ($txt.Substring(0,[Math]::Min(400,$txt.Length))) } }
        403 { Write-Err2 "HTTP 403 —— 鉴权被拒绝，检查 Token / API Key 或权限。"; if ($txt) { Write-Host ($txt.Substring(0,[Math]::Min(400,$txt.Length))) } }
        404 { Write-Err2 "HTTP 404 —— 路径不对，检查 BASE_URL 是否需要去掉/加上 /v1 之类前缀。"; if ($txt) { Write-Host ($txt.Substring(0,[Math]::Min(300,$txt.Length))) } }
        default { Write-Warn2 "HTTP $code"; if ($txt) { Write-Host ($txt.Substring(0,[Math]::Min(500,$txt.Length))) } }
      }
    } else {
      Write-Err2 "无法建立连接 (DNS / 网络 / TLS): $($_.Exception.Message)"
    }
  } catch {
    # PowerShell 7 throws HttpResponseException instead of WebException
    $msg = $_.Exception.Message
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $code = [int]$_.Exception.Response.StatusCode
      if ($code -eq 200) { Write-Ok "HTTP 200 —— 正常 ✅" }
      elseif ($code -eq 400) { Write-Warn2 "HTTP 400 —— 已连通、鉴权可能通过；多为模型名不被接受。" }
      elseif ($code -in 401,403) { Write-Err2 "HTTP $code —— 鉴权失败，检查 Token / API Key。" }
      elseif ($code -eq 404) { Write-Err2 "HTTP 404 —— 路径不对，检查 BASE_URL。" }
      else { Write-Warn2 "HTTP $code —— $msg" }
    } else {
      Write-Err2 "请求失败: $msg"
    }
  }
  Pause-Menu
}

# --------------------------------------------------------------------------- #
# Run claude
# --------------------------------------------------------------------------- #
function Invoke-Claude {
  Write-Hr
  $b = Get-ClaudeCmd
  if (-not $b) { Write-Err2 "未安装 Claude Code，请先选 1"; Pause-Menu; return }
  # Load managed config.env into this session so it works without reopening a window.
  $cf = Get-ConfigMap
  foreach ($k in $cf.Keys) { if ($cf[$k]) { Set-Item -Path "Env:$k" -Value $cf[$k] } }
  Write-Info "启动: $b"
  & $b
  Pause-Menu
}

# --------------------------------------------------------------------------- #
# Self install / uninstall
# --------------------------------------------------------------------------- #
function Install-Self {
  New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null

  # 1. place a copy of this script
  $srcPath = $PSCommandPath
  $sameFile = $srcPath -and (Test-Path $script:SelfPs1) -and `
    ((Resolve-Path -LiteralPath $srcPath -ErrorAction SilentlyContinue).Path -eq (Resolve-Path -LiteralPath $script:SelfPs1).Path)
  if ($sameFile) {
    Write-Ok "管理命令已是最新 (从自身运行): $script:SelfPs1"
  } elseif ($srcPath -and (Test-Path $srcPath)) {
    Copy-Item -LiteralPath $srcPath -Destination $script:SelfPs1 -Force
    Write-Ok "已保存: $script:SelfPs1"
  } else {
    Write-Info "从仓库获取脚本: $script:RawUrl"
    Invoke-RestMethod -Uri $script:RawUrl -OutFile $script:SelfPs1
    Write-Ok "已保存: $script:SelfPs1"
  }

  # 2. .cmd shim so cmd.exe / any shell on PATH can call `claude-maas`
  $cmd = @(
    '@echo off'
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-maas.ps1" %*'
  ) -join "`r`n"
  Set-Content -LiteralPath $script:SelfCmd -Value $cmd -Encoding ascii
  Write-Ok "已创建 shim: $script:SelfCmd"

  # 3. ensure ConfigDir on User PATH
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $userPath) { $userPath = '' }
  $parts = $userPath.Split(';') | Where-Object { $_ -ne '' }
  if ($parts -notcontains $script:ConfigDir) {
    $newPath = (@($script:ConfigDir) + $parts) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    $env:Path = "$script:ConfigDir;$env:Path"
    Write-Ok "已把 $script:ConfigDir 加入用户 PATH"
  }

  # 4. PowerShell profile function (nice for PS users; also refreshes without new window)
  $profilePath = $PROFILE.CurrentUserAllHosts
  New-Item -ItemType Directory -Force -Path (Split-Path $profilePath) | Out-Null
  if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath | Out-Null }
  $content = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
  if ($null -eq $content) { $content = '' }
  if ($content -notmatch [regex]::Escape($script:ProfileMarkBegin)) {
    $block = @(
      ''
      $script:ProfileMarkBegin
      "function claude-maas { & '$script:SelfPs1' @args }"
      $script:ProfileMarkEnd
    ) -join "`r`n"
    Add-Content -LiteralPath $profilePath -Value $block -Encoding utf8
    Write-Ok "已在 PowerShell profile 添加 claude-maas 函数: $profilePath"
  }

  Write-Ok "管理命令安装完成。新开窗口后运行:  claude-maas"
  Write-Info "本会话可直接用:  & '$script:SelfPs1'"
}

function Uninstall-All {
  Write-Hr
  Write-Warn2 "即将移除 claude-maas 的配置与管理命令。"
  if (-not (Confirm-YN "继续?" 'N')) { Pause-Menu; return }

  if (Confirm-YN "删除 settings.json 中的受管 env 键?" 'Y') {
    $empty = @{}; foreach ($k in $script:ManagedKeys) { $empty[$k] = '' }
    [void](Save-SettingsEnv $empty)
  }

  if (Confirm-YN "删除用户级系统环境变量?" 'Y') {
    foreach ($k in $script:ManagedKeys) {
      [Environment]::SetEnvironmentVariable($k, $null, 'User')
      Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue
    }
    Write-Ok "已删除用户级 ANTHROPIC_* 受管变量"
  }

  # remove profile function block
  $profilePath = $PROFILE.CurrentUserAllHosts
  if (Test-Path $profilePath) {
    $lines = Get-Content -LiteralPath $profilePath
    $out = @(); $skip = $false
    foreach ($l in $lines) {
      if ($l -eq $script:ProfileMarkBegin) { $skip = $true; continue }
      if ($l -eq $script:ProfileMarkEnd)   { $skip = $false; continue }
      if (-not $skip) { $out += $l }
    }
    Set-Content -LiteralPath $profilePath -Value $out -Encoding utf8
    Write-Ok "已从 PowerShell profile 移除 claude-maas 函数"
  }

  # remove ConfigDir from User PATH
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath) {
    $parts = $userPath.Split(';') | Where-Object { $_ -ne '' -and $_ -ne $script:ConfigDir }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Write-Ok "已从用户 PATH 移除 $script:ConfigDir"
  }

  if (Confirm-YN "删除配置目录 $script:ConfigDir ?" 'Y') {
    Remove-Item -LiteralPath $script:ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "已删除 $script:ConfigDir"
  }

  $b = Get-ClaudeCmd
  if ($b -and (Confirm-YN "同时卸载 Claude Code CLI 本体? ($b)" 'N')) {
    try { & $b uninstall } catch { Write-Warn2 "claude uninstall 不可用，请按安装方式手动卸载" }
  }

  Write-Ok "卸载完成。请重开窗口。"
  Pause-Menu
}

# --------------------------------------------------------------------------- #
# Menu
# --------------------------------------------------------------------------- #
function Show-Banner {
  Clear-Host
  Write-Host ''
  Write-Host "   claude-maas  ·  Claude Code CLI + MaaS 一键安装 / 管理" -ForegroundColor Blue
  $psv = $PSVersionTable.PSVersion.ToString()
  Write-Host "   v$script:Version   windows   PowerShell $psv" -ForegroundColor DarkGray
  Write-Hr
  $b = Get-ClaudeCmd
  if ($b) { Write-Host "  Claude Code : $(Get-ClaudeVersion)" -ForegroundColor Green }
  else    { Write-Host "  Claude Code : 未安装" -ForegroundColor Red }
  $sj = Read-SettingsEnv
  $cf = Get-ConfigMap
  $configured = ($sj -and $sj['ANTHROPIC_BASE_URL']) -or ($cf['ANTHROPIC_BASE_URL'])
  if ($configured) { Write-Host "  MaaS 配置   : 已配置" -ForegroundColor Green }
  else             { Write-Host "  MaaS 配置   : 未配置" -ForegroundColor Red }
  if (Test-Path $script:SelfPs1) { Write-Host "  管理命令    : claude-maas 已安装" -ForegroundColor Green }
  else { Write-Host "  管理命令    : (本次为一次性运行)" -ForegroundColor DarkGray }
  Write-Hr
}

function Show-Menu {
  while ($true) {
    Show-Banner
    Write-Host "  1)  安装 / 更新 Claude Code CLI"
    Write-Host "  2)  配置 MaaS 连接 (Base URL / Token / 模型)"
    Write-Host "  3)  查看当前配置"
    Write-Host "  4)  测试连接"
    Write-Host "  5)  启动 Claude Code"
    Write-Host "  8)  安装 / 更新 ""claude-maas"" 管理命令"
    Write-Host "  9)  卸载 (配置 / 管理命令 / 可选卸载 CLI)"
    Write-Host "  0)  退出"
    Write-Hr
    $choice = Read-Host '请选择'
    switch ($choice) {
      '1' { Install-ClaudeCode }
      '2' { Configure-Maas }
      '3' { Show-Config }
      '4' { Invoke-MaasTest }
      '5' { Invoke-Claude }
      '8' { Install-Self; Pause-Menu }
      '9' { Uninstall-All }
      '0' { Write-Host 'bye.'; return }
      'q' { return }
      default { if ($choice) { Write-Err2 "无效选项: $choice"; Start-Sleep -Milliseconds 800 } }
    }
  }
}

function Show-Usage {
@"
claude-maas v$script:Version — Claude Code CLI + MaaS 一键安装 / 管理 (Windows)

用法:
  claude-maas                 打开交互菜单
  claude-maas install         安装/更新 Claude Code CLI
  claude-maas config          配置 MaaS 连接
  claude-maas show            打印当前配置
  claude-maas test            测试到 MaaS 的连接
  claude-maas run             加载受管环境并启动 claude
  claude-maas self-install    安装为 'claude-maas' 命令 (函数 + .cmd shim)
  claude-maas uninstall       移除配置 / 管理命令
  claude-maas help            显示本帮助
"@ | Write-Host
}

# --------------------------------------------------------------------------- #
# Entrypoint
# --------------------------------------------------------------------------- #
$cmd = if ($args.Count -ge 1) { [string]$args[0] } else { '' }

# First run via `irm | iex`: offer to install the manager command.
if (-not $cmd -and -not (Test-Path $script:SelfPs1)) {
  Show-Banner
  Write-Host "首次运行。安装 'claude-maas' 管理命令后，之后可随时用它重开此菜单。"
  if (Confirm-YN "现在安装管理命令?" 'Y') { Install-Self; Write-Host ''; Start-Sleep -Milliseconds 600 }
}

switch ($cmd) {
  ''            { Show-Menu }
  'menu'        { Show-Menu }
  'install'     { Install-ClaudeCode }
  'config'      { Configure-Maas }
  'configure'   { Configure-Maas }
  'show'        { Show-Config }
  'status'      { Show-Config }
  'test'        { Invoke-MaasTest }
  'run'         { Invoke-Claude }
  'self-install'{ Install-Self }
  'uninstall'   { Uninstall-All }
  'remove'      { Uninstall-All }
  '-h'          { Show-Usage }
  '--help'      { Show-Usage }
  'help'        { Show-Usage }
  '-v'          { Write-Host $script:Version }
  '--version'   { Write-Host $script:Version }
  default       { Write-Err2 "未知命令: $cmd"; Show-Usage; exit 2 }
}

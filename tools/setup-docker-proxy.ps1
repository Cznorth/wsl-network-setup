[CmdletBinding()]
param(
    [string]$Name,
    [string]$ResHost,
    [int]$ResPort = 443,
    [string]$ResUser,
    [string]$ResPass,
    [string]$ClashHost,
    [int]$ClashPort = 7890,
    [switch]$Direct,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$stateRoot = Join-Path $repoRoot 'docker-proxies'
$stateFile = Join-Path $stateRoot 'instances.json'
$composeFile = Join-Path $repoRoot 'docker-compose.yml'
$wslDistro = 'Ubuntu-24.04'

function Read-DotEnv([string]$Path) {
    $result = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                $result[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
            }
        }
    }
    return $result
}

function Test-PortFree([int]$Port) {
    try {
        $listeners = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop
        return ($null -eq $listeners)
    } catch {
        return $true
    }
}

function Get-FreePortPair([int]$Start = 7895) {
    for ($port = $Start; $port -lt 65535; $port += 2) {
        if ((Test-PortFree $port) -and (Test-PortFree ($port + 1))) {
            return @($port, $port + 1)
        }
    }
    throw '没有找到连续的可用端口。'
}

function Convert-ToWslPath([string]$Path) {
    if ($Path -match '^(?<drive>[cCdD]):\\(?<rest>.*)$') {
        $drive = $Matches.drive.ToLowerInvariant()
        $rest = $Matches.rest -replace '\\', '/'
        if ([string]::IsNullOrEmpty($rest)) { return "/mnt/$drive" }
        return "/mnt/$drive/$rest"
    }
    throw "当前目录必须位于 C: 或 D: 盘：$Path"
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw '找不到 docker 命令，请先启动 Docker Desktop。'
}

$defaults = Read-DotEnv (Join-Path $repoRoot '.env')
if (-not $Name) {
    $existing = @()
    if (Test-Path -LiteralPath $stateFile) {
        $existing = @(Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json).instances
    }
    $n = 1
    while ($existing | Where-Object { $_.name -eq "proxy$n" }) { $n++ }
    $Name = "proxy$n"
}
if ($Name -notmatch '^[a-z0-9][a-z0-9_-]*$') {
    throw '实例名只能使用小写字母、数字、下划线和短横线。'
}

$ResHost = if ($ResHost) { $ResHost } else { $defaults['RES_HOST'] }
$ResUser = if ($ResUser) { $ResUser } else { $defaults['RES_USER'] }
$ResPass = if ($ResPass) { $ResPass } else { $defaults['RES_PASS'] }
$ResPort = if ($PSBoundParameters.ContainsKey('ResPort')) { $ResPort } elseif ($defaults['RES_PORT']) { [int]$defaults['RES_PORT'] } else { 443 }
$ClashHost = if ($ClashHost) { $ClashHost } else { $defaults['CLASH_HOST'] }
$ClashPort = if ($PSBoundParameters.ContainsKey('ClashPort')) { $ClashPort } elseif ($defaults['CLASH_PORT']) { [int]$defaults['CLASH_PORT'] } else { 7890 }

if (-not $ResHost) { $ResHost = Read-Host '住宅 SOCKS5 地址' }
if (-not $ResUser) { $ResUser = Read-Host '住宅用户名' }
if (-not $ResPass) { $ResPass = Read-Host '住宅密码' }
if (-not $ClashHost) { $ClashHost = 'host.docker.internal' }

$instances = @()
if (Test-Path -LiteralPath $stateFile) {
    $parsed = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
    if ($parsed.instances) { $instances = @($parsed.instances) }
}
$old = $instances | Where-Object { $_.name -eq $Name }
$startPort = if ($old) { [int]$old.httpPort } else { 7895 + (($instances.Count) * 2) }
$ports = Get-FreePortPair $startPort
$httpPort = $ports[0]
$socksPort = $ports[1]

$instanceDir = Join-Path $stateRoot $Name
New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null
$instanceEnv = Join-Path $instanceDir '.env'
$useClash = if ($Direct) { '0' } else { '1' }
$dnsUpstream = if ($defaults['DNS_UPSTREAM']) { $defaults['DNS_UPSTREAM'] } else { '8.8.8.8:53' }

@"
RES_HOST=$ResHost
RES_PORT=$ResPort
RES_USER=$ResUser
RES_PASS=$ResPass
USE_CLASH=$useClash
CLASH_HOST=$ClashHost
CLASH_PORT=$ClashPort
DNS_UPSTREAM=$dnsUpstream
HTTP_PORT=$httpPort
SOCKS_PORT=$socksPort
PROXY_BIND_ADDRESS=127.0.0.1
"@ | Set-Content -Encoding ascii -NoNewline -LiteralPath $instanceEnv

$wslEnvPath = "/home/cznorth/wsl-network-setup/docker-proxies/$Name/.env"
wsl.exe -d $wslDistro -- chmod 600 $wslEnvPath | Out-Null

$project = "wslproxy-$Name"
$record = [ordered]@{
    name = $Name
    project = $project
    envFile = $instanceEnv
    httpPort = $httpPort
    socksPort = $socksPort
}
$instances = @($instances | Where-Object { $_.name -ne $Name }) + [pscustomobject]$record
@{ instances = $instances } | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -LiteralPath $stateFile

function Invoke-Compose([string[]]$Args) {
    & docker compose --project-name $project --env-file $instanceEnv --file $composeFile @Args
    if ($LASTEXITCODE -ne 0) { throw "docker compose 失败，退出码 $LASTEXITCODE" }
}

if (-not $NoStart) {
    Invoke-Compose @('up', '-d', '--build', '--force-recreate')
}

$profileBlock = @"

# Docker transparent proxy shortcuts (managed by setup-docker-proxy.ps1)
function Enter-DockerProxy {
    param([Parameter(Mandatory=`$true)][string]`$Name)
    `$repo = '$repoRoot'
    `$state = Join-Path `$repo 'docker-proxies/instances.json'
    `$items = @(Get-Content -Raw -LiteralPath `$state | ConvertFrom-Json).instances
    `$item = `$items | Where-Object { `$_.name -eq `$Name }
    if (-not `$item) { throw "找不到 Docker 代理实例：`$Name" }
    `$hostPath = (Get-Location).Path
    if (`$hostPath -notmatch '^(?<drive>[cCdD]):\\(?<rest>.*)`$') { throw "当前目录必须位于 C: 或 D: 盘：`$hostPath" }
    `$drive = `$Matches.drive.ToLowerInvariant(); `$rest = `$Matches.rest -replace '\\', '/'
    `$containerPath = if ([string]::IsNullOrEmpty(`$rest)) { "/mnt/`$drive" } else { "/mnt/`$drive/`$rest" }
    `$args = @('--project-name', `$item.project, '--env-file', `$item.envFile, '--file', (Join-Path `$repo 'docker-compose.yml'))
    `$running = & docker compose @args ps --status running -q residential-proxy 2>`$null
    if (-not `$running) { & docker compose @args up -d --build; if (`$LASTEXITCODE -ne 0) { throw '启动 Docker 代理失败。' } }
    & docker compose @args exec -w `$containerPath residential-proxy bash
}
"@
$aliasIndex = if ($Name -match '^proxy(?<n>\d+)$') { $Matches.n } else { $instances.Count }
$profileBlock += "`r`nfunction bash$aliasIndex { Enter-DockerProxy -Name '$Name' }`r`n"

foreach ($profile in @($PROFILE, 'D:\Cznorth\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1') | Select-Object -Unique) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $profile) | Out-Null
    $current = if (Test-Path -LiteralPath $profile) { Get-Content -Raw -LiteralPath $profile } else { '' }
    # Append the managed block even when an older hard-coded bash1 exists;
    # PowerShell uses the later definition and therefore upgrades it in place.
    if ($current -notmatch 'Docker transparent proxy shortcuts \(managed by setup-docker-proxy\.ps1\)') {
        Add-Content -Encoding utf8 -LiteralPath $profile -Value $profileBlock
    } elseif ($current -notmatch "function bash$aliasIndex\s*\{") {
        # A later instance (bash2, bash3, ...) needs only its new alias.
        Add-Content -Encoding utf8 -LiteralPath $profile -Value "`r`nfunction bash$aliasIndex { Enter-DockerProxy -Name '$Name' }`r`n"
    }
}

Write-Host "实例 $Name 已配置：HTTP $httpPort，SOCKS5 $socksPort，快捷命令 bash$aliasIndex"

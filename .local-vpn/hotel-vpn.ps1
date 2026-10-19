[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'status', 'list', 'test', 'url', 'open')]
    [string]$Action = 'status',
    [string]$Device
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $moduleRoot 'config.local.json'
$devicesPath = Join-Path $moduleRoot 'devices.json'
$stateDir = Join-Path $env:LOCALAPPDATA 'SovaMiraHotelVpn'
$pidPath = Join-Path $stateDir 'openvpn.pid'
$logPath = Join-Path $stateDir 'openvpn.log'
$runtimeProfilePath = Join-Path $stateDir 'hotel-profile.runtime.ovpn'

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Не найден файл: $Path"
    }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$config = Read-Json $configPath
$devices = @(Read-Json $devicesPath)

function Restore-RuntimeProfile {
    $encryptedPath = Join-Path $moduleRoot $config.encryptedProfile
    if (-not (Test-Path -LiteralPath $encryptedPath)) {
        throw "Зашифрованная копия VPN-профиля не найдена: $encryptedPath"
    }
    Add-Type -AssemblyName System.Security
    $entropy = [Text.Encoding]::UTF8.GetBytes('sova-mira-site/hotel-vpn-profile/v1')
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            [IO.File]::ReadAllBytes($encryptedPath),
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
    } catch {
        throw 'Не удалось расшифровать VPN-профиль. DPAPI-копия привязана к текущей учётной записи Windows.'
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $actualHash = ([BitConverter]::ToString($sha256.ComputeHash($plain))).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }
    if ($actualHash -ne $config.profileSha256) {
        throw 'Контрольная сумма расшифрованного VPN-профиля не совпадает с сохранённой.'
    }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [IO.File]::WriteAllBytes($runtimeProfilePath, $plain)
    $runtimeProfilePath
}

function Get-VpnProcess {
    if (Test-Path -LiteralPath $pidPath) {
        $savedPid = 0
        if ([int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$savedPid)) {
            $process = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($null -ne $process -and $process.ProcessName -eq 'openvpn') { return $process }
        }
    }
    # Подхватывает ранее запущенный экземпляр при первом переходе на этот модуль.
    $running = @(Get-Process -Name 'openvpn' -ErrorAction SilentlyContinue)
    if ($running.Count -eq 1) { return $running[0] }
    if ($running.Count -gt 1) { throw 'Обнаружено несколько процессов OpenVPN; автоматический выбор небезопасен.' }
    return $null
}

function Get-HotelRoute {
    Get-NetRoute -DestinationPrefix "$($config.hotelSubnet)/24" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric |
        Select-Object -First 1
}

function Get-Device([string]$Query) {
    if ([string]::IsNullOrWhiteSpace($Query)) {
        throw 'Укажите устройство: router, camera1, camera2, camera3 или printer.'
    }
    $needle = $Query.Trim().ToLowerInvariant()
    $match = $devices | Where-Object {
        $_.name.ToLowerInvariant() -eq $needle -or @($_.aliases | ForEach-Object { $_.ToLowerInvariant() }) -contains $needle
    } | Select-Object -First 1
    if ($null -eq $match) { throw "Неизвестное устройство: $Query" }
    $match
}

function Show-Status {
    $process = Get-VpnProcess
    $route = Get-HotelRoute
    $wideRoutes = @()
    if ($null -ne $route) {
        $wideRoutes = @(Get-NetRoute -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceIndex -eq $route.InterfaceIndex -and $_.DestinationPrefix -in @('0.0.0.0/1', '128.0.0.0/1')
        })
    }
    [pscustomobject]@{
        Connected = ($null -ne $process -and $null -ne $route)
        ProcessId = if ($process) { $process.Id } else { $null }
        HotelRoute = if ($route) { $route.DestinationPrefix } else { $null }
        Interface = if ($route) { $route.InterfaceAlias } else { $null }
        SplitTunnel = ($null -ne $route -and $wideRoutes.Count -eq 0)
        Log = $logPath
    }
}

function Start-HotelVpn {
    $current = Show-Status
    if ($current.Connected -and $current.SplitTunnel) {
        Write-Output 'VPN гостиницы уже подключён в split-tunnel режиме.'
        return
    }
    if (-not (Test-Path -LiteralPath $config.openVpnExe)) { throw "OpenVPN не найден: $($config.openVpnExe)" }
    if ($null -ne (Get-VpnProcess)) {
        throw 'OpenVPN уже запущен, но его маршрут не соответствует безопасному режиму. Сначала выполните stop.'
    }

    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    $runtimeProfile = Restore-RuntimeProfile
    $quote = { param([string]$Value) '"' + $Value.Replace('"', '\"') + '"' }
    $arguments = @(
        '--config', (& $quote $runtimeProfile),
        '--pull-filter', 'ignore', (& $quote 'redirect-gateway'),
        '--pull-filter', 'ignore', (& $quote 'dhcp-option DNS'),
        '--route', $config.hotelSubnet, $config.hotelMask, 'vpn_gateway', '1',
        '--writepid', (& $quote $pidPath),
        '--log', (& $quote $logPath)
    ) -join ' '

    Start-Process -FilePath $config.openVpnExe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(35)
    do {
        Start-Sleep -Milliseconds 700
        $status = Show-Status
        if ($status.Connected) { break }
    } while ((Get-Date) -lt $deadline)

    $status = Show-Status
    if (-not $status.Connected) { throw "VPN не подключился. Проверьте журнал: $logPath" }
    if (-not $status.SplitTunnel) { throw 'VPN подключился, но обнаружен маршрут всего трафика. Выполните stop.' }
    Write-Output "VPN гостиницы подключён: $($status.HotelRoute) через $($status.Interface)."
}

function Stop-HotelVpn {
    $process = Get-VpnProcess
    $route = Get-HotelRoute
    if ($null -ne $process -or $null -ne $route) {
        $commands = @("`$ErrorActionPreference = 'Stop'")
        if ($null -ne $process) {
            $commands += "Stop-Process -Id $($process.Id) -Force -ErrorAction SilentlyContinue"
            $commands += 'Start-Sleep -Milliseconds 800'
        }
        if ($null -ne $route) {
            $interfaceIndex = [int]$route.InterfaceIndex
            foreach ($prefix in @('192.168.0.0/24', '0.0.0.0/1', '128.0.0.0/1')) {
                $commands += "Remove-NetRoute -DestinationPrefix '$prefix' -InterfaceIndex $interfaceIndex -Confirm:`$false -ErrorAction SilentlyContinue"
            }
        }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($commands -join '; ')))
        $result = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if ($result.ExitCode -ne 0) { throw "Не удалось полностью отключить VPN, код $($result.ExitCode)." }
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $runtimeProfilePath -Force -ErrorAction SilentlyContinue
    Write-Output 'VPN гостиницы отключён.'
}

switch ($Action) {
    'start' { Start-HotelVpn }
    'stop' { Stop-HotelVpn }
    'status' { Show-Status | Format-List }
    'list' { $devices | Select-Object name, label, url | Format-Table -AutoSize }
    'test' {
        Start-HotelVpn
        $devices | ForEach-Object {
            $probe = Test-NetConnection -ComputerName $_.host -Port $_.port -InformationLevel Quiet -WarningAction SilentlyContinue
            [pscustomobject]@{ Name = $_.name; Address = $_.host; Port = $_.port; Reachable = $probe }
        } | Format-Table -AutoSize
    }
    'url' { (Get-Device $Device).url }
    'open' {
        Start-HotelVpn
        $target = Get-Device $Device
        Start-Process $target.url
        Write-Output "Открыто: $($target.label) — $($target.url)"
    }
}

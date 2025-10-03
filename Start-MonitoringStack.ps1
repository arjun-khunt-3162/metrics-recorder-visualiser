<#
.SYNOPSIS
    Starts Grafana, Prometheus and Windows Exporter each in their own new PowerShell window.

.DESCRIPTION
    Convenience script to spin up the local monitoring stack from the Programs directory.
    Each target process is started in a separate PowerShell window using Start-Process -Verb RunAs (optional) so you can see logs.

.PARAMETER NoGrafana
    Skip starting Grafana.

.PARAMETER NoPrometheus
    Skip starting Prometheus.

.PARAMETER NoWindowsExporter
    Skip starting windows_exporter.

.PARAMETER Elevated
    Start processes elevated (Run as Administrator). Some exporters / low ports may require this.

.EXAMPLE
    .\Start-MonitoringStack.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoGrafana,
    [switch]$NoPrometheus,
    [switch]$NoWindowsExporter,
    [switch]$Elevated,
    [Alias('h', '?')][switch] $Help
)

$ErrorActionPreference = 'Stop'

function Resolve-RootPath {
    param([string]$Relative)
    return Join-Path -Path $PSScriptRoot -ChildPath $Relative
}

$programsRoot = Resolve-RootPath 'Programs'
if (-not (Test-Path $programsRoot)) {
    throw "Programs directory not found at $programsRoot"
}

$grafanaDir = Get-ChildItem -Path (Join-Path $programsRoot 'grafana*') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$promDir = Get-ChildItem -Path (Join-Path $programsRoot 'prometheus*') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$winExpDir = Get-ChildItem -Path (Join-Path $programsRoot 'windows_exporter*') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1

if (-not $NoGrafana -and -not $grafanaDir) { Write-Warning 'Grafana directory not found.' }
if (-not $NoPrometheus -and -not $promDir) { Write-Warning 'Prometheus directory not found.' }
if (-not $NoWindowsExporter -and -not $winExpDir) { Write-Warning 'Windows Exporter directory not found.' }

function Start-NewWindowProcess {
    param(
        [string]$Title,
        [string]$WorkingDirectory,
        [string]$FilePath,
        [string]$Arguments
    )
    if (-not (Test-Path $FilePath)) { Write-Warning "Executable not found: $FilePath"; return }

    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = (Get-Command powershell.exe).Source }

    $inner = @(
        "Write-Host 'Starting $Title...' -ForegroundColor Cyan",
        "Set-Location `"$WorkingDirectory`"",
        "& `"$FilePath`" $Arguments",
        "Write-Host '$Title process exited (code $LastExitCode). Press Enter to close.' -ForegroundColor Yellow",
        "[void][System.Console]::ReadLine()"
    ) -join '; '

    $startParams = @{ FilePath = $pwsh; ArgumentList = @('-NoExit', '-Command', $inner); WorkingDirectory = $WorkingDirectory; WindowStyle = 'Normal' }
    if ($Elevated) { $startParams.Verb = 'RunAs' }

    try {
        Start-Process @startParams | Out-Null
        Write-Host "Launched $Title in new window." -ForegroundColor Green
    }
    catch {
        Write-Warning (("Failed to launch {0}: {1}" -f $Title, $_))
    }
}

function Show-Usage {
    @'
Start-MonitoringStack.ps1 - Convenience script to start Grafana, Prometheus and Windows Exporter

USAGE:
    .\Start-MonitoringStack.ps1 [-NoGrafana] [-NoPrometheus] [-NoWindowsExporter] [-Elevated] [-Help]

OPTIONS:
    -NoGrafana         Skip starting Grafana.
    -NoPrometheus      Skip starting Prometheus.
    -NoWindowsExporter Skip starting Windows Exporter.
    -Elevated          Start processes elevated (Run as Administrator).
    -Help (-h, -?)     Show this help message and exit.

EXAMPLE:
    .\Start-MonitoringStack.ps1 -Elevated
'@
}

if ($Help) {
    Show-Usage
    return
}

if (-not $NoGrafana -and $grafanaDir) {
    $grafanaBin = Join-Path $grafanaDir.FullName 'bin'
    $grafanaExe = Join-Path $grafanaBin 'grafana.exe'
    $grafArgs = "server"
    Start-NewWindowProcess -Title "Grafana" -WorkingDirectory $grafanaBin -FilePath $grafanaExe -Arguments $grafArgs
}

if (-not $NoPrometheus -and $promDir) {
    $promExe = Join-Path $promDir.FullName 'prometheus.exe'
    $promArgs = "--config.file=prometheus-config.yaml --log.level=warn --storage.tsdb.retention.size=0 --storage.tsdb.retention.time=45d"
    Start-NewWindowProcess -Title 'Prometheus' -WorkingDirectory $promDir.FullName -FilePath $promExe -Arguments $promArgs
}

if (-not $NoWindowsExporter -and $winExpDir) {
    $exporterExe = Get-ChildItem -Path $winExpDir.FullName -Filter '*.exe' | Select-Object -First 1 | ForEach-Object FullName
    $expArgs = "--config.file=windows_exporter-config.yml"
    Start-NewWindowProcess -Title "Windows Exporter" -WorkingDirectory $winExpDir.FullName -FilePath $exporterExe -Arguments $expArgs
}

Write-Host 'All requested processes launched.' -ForegroundColor Magenta
Write-Host 'To stop processes:' -ForegroundColor Cyan
Write-Host ' - Close each window or press Ctrl+C inside it.' -ForegroundColor Yellow
Write-Host ' - Or run the following in an elevated PowerShell to kill by process name:' -ForegroundColor Yellow
Write-Host '     Get-Process -Name "grafana*","prometheus*","windows_exporter*" -ErrorAction SilentlyContinue | Stop-Process -Force' -ForegroundColor White

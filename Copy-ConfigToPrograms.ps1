<#
.SYNOPSIS
    Copy configuration assets from the `Config` tree into the matching `Programs` versioned folders.

.DESCRIPTION
    For each component folder found under the Config root (e.g. grafana, prometheus, windows_exporter),
    this script locates one or more matching installed program directories under the Programs root whose
    names start with the component name — for example:

        Config\grafana\...  -> Programs\grafana-12.2.0\...
        Config\prometheus\... -> Programs\prometheus-3.6.0.windows-amd64\...
        Config\windows_exporter\... -> Programs\windows_exporter-0.31.3-amd64\...

    All files and subdirectories beneath each component's config root are copied into the target program
    folder while preserving their relative folder structure. Existing files can optionally be backed up.

.PARAMETER ConfigRoot
    Root folder containing component configuration folders. Defaults to a `Config` folder located next to this script.

.PARAMETER ProgramsRoot
    Root folder containing installed program version folders. Defaults to a `Programs` folder located next to this script.

.PARAMETER Component
    One or more component names to restrict the copy operation (e.g. grafana, prometheus). If omitted, all immediate
    child folders of ConfigRoot are processed.

.PARAMETER AppyToAllVersions
    If set, copy config into ALL matching version folders. By default only the most recently modified matching folder
    (heuristic for "current" version) is used per component.

.PARAMETER Backup
    If set, existing destination files are first backed up with a UTC timestamp suffix (.bak.YYYYMMDDHHMMSS) before overwrite.

.PARAMETER DryRun
    Show what would be copied without making any changes.

.EXAMPLE
    # Preview operations for every component
    .\Copy-ConfigToPrograms.ps1 -DryRun

.EXAMPLE
    # Copy only grafana configs into the latest grafana-* folder, backing up existing files
    .\Copy-ConfigToPrograms.ps1 -Component prometheus,grafana -Backup

.EXAMPLE
    # Copy configs for all components into all matching version folders
    .\Copy-ConfigToPrograms.ps1 -AppyToAllVersions
#>
param(
    [Parameter()] [string] $ConfigRoot = (Join-Path -Path $PSScriptRoot -ChildPath 'Config'),
    [Parameter()] [string] $ProgramsRoot = (Join-Path -Path $PSScriptRoot -ChildPath 'Programs'),
    [Parameter()] [string[]] $Component,
    [switch] $AppyToAllVersions,
    [switch] $Backup,
    [switch] $DryRun,
    [Alias('h', '?')][switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Auto-detect alternate repo-relative locations if defaults are missing ---
try {
    if (-not (Test-Path -LiteralPath $ConfigRoot -PathType Container)) {
        $altConfig = Join-Path -Path $PSScriptRoot -ChildPath 'Observability/metrics/Config'
        if (Test-Path -LiteralPath $altConfig -PathType Container) {
            $ConfigRoot = (Resolve-Path -LiteralPath $altConfig).Path
        }
    }
    if (-not (Test-Path -LiteralPath $ProgramsRoot -PathType Container)) {
        $altPrograms = Join-Path -Path $PSScriptRoot -ChildPath 'Observability/metrics/Programs'
        if (Test-Path -LiteralPath $altPrograms -PathType Container) {
            $ProgramsRoot = (Resolve-Path -LiteralPath $altPrograms).Path
        }
    }
}
catch {
    Write-Warning "Path auto-detection encountered an issue: $($_.Exception.Message)"
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO ] $Message" -ForegroundColor Cyan
}

function Write-Action {
    param([string]$Message)
    Write-Host "[COPY ] $Message" -ForegroundColor Green
}

function Write-Backup {
    param([string]$Message)
    Write-Host "[BACK ] $Message" -ForegroundColor Yellow
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN ] $Message" -ForegroundColor DarkYellow
}

function Show-Usage {
    @'
Copy-ConfigToPrograms.ps1 - Copy configurations into programs folders.

SYNTAX:
    .\Copy-ConfigToPrograms.ps1 [-Component <name> [<name>...]] [-AppyToAllVersions] [-Backup] [-DryRun]
                                 [-ConfigRoot <path>] [-ProgramsRoot <path>] [-Help]

PARAMETERS:
    -Component <string[]>   Restrict to specific components (default: all component folders under ConfigRoot).
    -AppyToAllVersions       Copy into every matching program folder (default: only most recent per component).
    -Backup                  Create timestamped .bak copies before overwriting existing destination files.
    -DryRun                  Show actions without copying or creating directories.
    -ConfigRoot <path>       Root containing component configuration folders (default: .\Config next to script).
    -ProgramsRoot <path>     Root containing installed program folders (default: .\Programs next to script).
    -Help (-h, -?)           Show this usage help and exit.

EXAMPLES:
    Preview all operations:
        .\Copy-ConfigToPrograms.ps1 -DryRun

    Copy only prometheus and grafana with backups:
        .\Copy-ConfigToPrograms.ps1 -Component prometheus,grafana -Backup

    Copy all components into every version folders:
        .\Copy-ConfigToPrograms.ps1 -AppyToAllVersions

    Custom roots:
        .\Copy-ConfigToPrograms.ps1 -ConfigRoot C:\cfg -ProgramsRoot C:\tools\Programs

NOTES:
    Also supports comment-based help: Get-Help .\Copy-ConfigToPrograms.ps1 -Full
'@
}

function Resolve-ComponentTargets {
    param(
        [string] $ProgramsRoot,
        [string] $ComponentName,
        [switch] $AppyToAllVersions
    )

    $pattern = "^{0}" -f [Regex]::Escape($ComponentName)
    $dirs = Get-ChildItem -LiteralPath $ProgramsRoot -Directory -ErrorAction Stop |
    Where-Object { $_.Name -match $pattern }

    if (-not $dirs) { return @() }

    if ($AppyToAllVersions) { return $dirs }

    # Choose the most recently modified folder as the "current" version.
    return $dirs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-RelativePath {
    param(
        [string] $BasePath,
        [string] $FullPath
    )
    return (Resolve-Path -LiteralPath $FullPath).Path.Substring( (Resolve-Path -LiteralPath $BasePath).Path.Length ).TrimStart(@('\', '/'))
}

function Copy-ComponentConfig {
    param(
        [string] $ComponentName,
        [string] $SourceRoot,
        [System.IO.DirectoryInfo[]] $TargetDirs,
        [switch] $Backup,
        [switch] $DryRun
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        Write-Warn "Source for component '$ComponentName' not found at $SourceRoot. Skipping."
        return
    }

    $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -File
    if (-not $allSourceFiles) {
        Write-Warn "No files found under $SourceRoot for component '$ComponentName'."
        return
    }

    foreach ($targetDir in $TargetDirs) {
        Write-Info "Component '$ComponentName' -> Target '$($targetDir.FullName)'"

        foreach ($file in $allSourceFiles) {
            $rel = Get-RelativePath -BasePath $SourceRoot -FullPath $file.FullName
            $destPath = Join-Path -Path $targetDir.FullName -ChildPath $rel
            $destDir = Split-Path -Path $destPath -Parent

            if (-not (Test-Path -LiteralPath $destDir)) {
                if ($DryRun) {
                    Write-Action "(DryRun) MKDIR $destDir"
                }
                else {
                    New-Item -ItemType Directory -Path $destDir | Out-Null
                }
            }

            if (Test-Path -LiteralPath $destPath -PathType Leaf) {
                if ($Backup) {
                    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
                    $backupPath = "$destPath.bak.$stamp"
                    if ($DryRun) {
                        Write-Backup "(DryRun) BACKUP $destPath -> $backupPath"
                    }
                    else {
                        Copy-Item -LiteralPath $destPath -Destination $backupPath
                        Write-Backup "$destPath -> $backupPath"
                    }
                }
            }

            if ($DryRun) {
                Write-Action "(DryRun) COPY $($file.FullName) -> $destPath"
            }
            else {
                Copy-Item -LiteralPath $file.FullName -Destination $destPath
                Write-Action "$rel"
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $ConfigRoot -PathType Container)) {
    throw "ConfigRoot '$ConfigRoot' does not exist."
}
if (-not (Test-Path -LiteralPath $ProgramsRoot -PathType Container)) {
    throw "ProgramsRoot '$ProgramsRoot' does not exist."
}

if ($Help) {
    Show-Usage
    return
}

$components = if ($Component) { $Component } else { (Get-ChildItem -LiteralPath $ConfigRoot -Directory | Select-Object -ExpandProperty Name) }
if (-not $components) { throw "No component folders found under $ConfigRoot" }

Write-Info "ConfigRoot   : $ConfigRoot"
Write-Info "ProgramsRoot : $ProgramsRoot"
Write-Info "Components   : $($components -join ', ')"
if ($DryRun) { Write-Info "Mode         : DRY RUN (no changes will be made)" }
if ($Backup) { Write-Info "Backup       : Enabled" }

$totalFiles = 0
$summary = @()

foreach ($comp in $components) {
    $sourceRoot = Join-Path -Path $ConfigRoot -ChildPath $comp
    $targets = Resolve-ComponentTargets -ProgramsRoot $ProgramsRoot -ComponentName $comp -AppyToAllVersions:$AppyToAllVersions
    if (-not $targets) {
        Write-Warn "No program directories matching '$comp*' under $ProgramsRoot"
        continue
    }
    $fileCount = (Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    $totalFiles += $fileCount
    $summary += [PSCustomObject]@{
        Component = $comp
        Targets   = (($targets | Select-Object -ExpandProperty FullName) -join '; ')
        Files     = $fileCount
    }
    Copy-ComponentConfig -ComponentName $comp -SourceRoot $sourceRoot -TargetDirs $targets -Backup:$Backup -DryRun:$DryRun
}

Write-Host ''
Write-Info 'Summary:'
foreach ($row in $summary) {
    Write-Host ("  {0,-18} -> {1} file(s) -> {2}" -f $row.Component, $row.Files, $row.Targets)
}
Write-Info "Total files considered: $totalFiles"
if ($DryRun) { Write-Info 'No changes were made due to DryRun.' }

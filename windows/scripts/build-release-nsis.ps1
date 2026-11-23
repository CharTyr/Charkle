<#
.SYNOPSIS
    Builds Charkle Windows x64 NSIS installer with bundled `charkle-cli.exe` sidecar and Figma Plugin resources.
#>
$ErrorActionPreference = "Stop"
$WindowsRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"

Push-Location $WindowsRoot
try {
    Write-Host "[1/3] Building release charkle-cli.exe..."
    cargo build --release -p charkle-cli
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $BinDir = Join-Path $WindowsRoot "src-tauri\binaries"
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    Copy-Item -Force `
        (Join-Path $WindowsRoot "target\release\charkle-cli.exe") `
        (Join-Path $BinDir "charkle-cli-x86_64-pc-windows-msvc.exe")

    Write-Host "[2/3] Building x64 NSIS installer via Tauri v2..."
    $TauriBin = Join-Path $WindowsRoot "ui\node_modules\.bin\tauri.cmd"
    & $TauriBin build --bundles nsis --config (Join-Path $WindowsRoot "src-tauri\tauri.nsis.conf.json")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "[3/3] NSIS Release artifacts:"
    Get-ChildItem (Join-Path $WindowsRoot "target\release\bundle\nsis") -Filter "*.exe" |
        Select-Object Name, Length, FullName | Format-Table -AutoSize
} finally {
    Pop-Location
}

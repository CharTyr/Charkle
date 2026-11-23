#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SkipUi
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$windowsRoot = Split-Path -Parent $PSScriptRoot
Push-Location $windowsRoot
try {
    Write-Host '==> Checking Windows toolchain prerequisites...' -ForegroundColor Cyan
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw 'Node.js 22+ is required. Install with: winget install OpenJS.NodeJS.LTS'
    }
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
        if (Test-Path (Join-Path $cargoBin 'cargo.exe')) {
            $env:Path = "$cargoBin;$env:Path"
        } else {
            throw 'Rust MSVC toolchain is required. Install with: winget install Rustlang.Rustup'
        }
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $vcInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $vcInstall) {
            Write-Warning 'VS 2022 C++ Build Tools (VC.Tools.x86.x64) not detected via vswhere.'
        }
    } else {
        Write-Warning 'vswhere.exe not found; ensure VS 2022 C++ Build Tools (Desktop development with C++) is installed.'
    }

    Write-Host '==> Syncing SVG icons...' -ForegroundColor Cyan
    node scripts/sync-icons.mjs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $uiPackageJson = Join-Path $windowsRoot 'ui\package.json'
    if (-not $SkipUi -and (Test-Path $uiPackageJson)) {
        Write-Host '==> Verifying UI workspace...' -ForegroundColor Cyan
        Push-Location (Join-Path $windowsRoot 'ui')
        try {
            npm run typecheck
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            npm test
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            npm run build
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally {
            Pop-Location
        }
    }

    Write-Host '==> Checking Rust formatting...' -ForegroundColor Cyan
    cargo fmt --all -- --check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host '==> Running cargo clippy...' -ForegroundColor Cyan
    cargo clippy --workspace --all-targets -- -D warnings
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host '==> Running cargo test --workspace...' -ForegroundColor Cyan
    cargo test --workspace
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host '==> Windows verification gate passed.' -ForegroundColor Green
} finally {
    Pop-Location
}

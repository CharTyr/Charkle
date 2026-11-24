---
name: charkle-windows-ship
description: >-
  Run Charkle's verified Windows pre-ship and release pipeline: icon sync, React/TypeScript
  typecheck/tests/build, strict zero-warning Rust formatting/clippy/workspace tests,
  PowerShell/Python repository purity and secret audit, Release x64 NSIS installer build with
  bundled charkle-cli sidecar, safe %LOCALAPPDATA%\Charkle deployment and detached Win32_Process
  relaunch, concurrent origin/main rebase sync with explicit Git push, and coordinated
  dual-platform GitHub Release publishing or non-destructive installer replacement that preserves
  macOS release notes verbatim. Use when finishing, verifying, packaging, locally deploying,
  releasing, or hot-replacing Windows builds in the Charkle repository.
---

# Charkle Windows Verify & Ship Runbook

Follow these steps in order whenever verifying, packaging, deploying locally, pushing, or releasing Windows changes in Charkle.

## 1. Strict Zero-Warning Verification Gate (UI + Rust)

Run the full Windows verification script from the repository root (ensures Node, Rust MSVC, icon sync, UI typecheck/tests/build, `cargo fmt --check`, `cargo clippy -D warnings`, and `cargo test --workspace` all pass with 0 warnings):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-windows.ps1
```

Confirm all UI unit tests and all Rust workspace tests pass with 0 warnings before packaging.

## 2. Repository Purity & Privacy Audit

Do **not** assume `rg` is installed on Windows PATH. Audit changed/added files with PowerShell `Select-String` (or `git grep` / Python `re`) for personal paths, credentials, and forbidden external reference/competitor/author mentions:

```powershell
$paths = git status --porcelain | ForEach-Object {
  $p = $_.Substring(3).Trim() -replace '^.* -> ', ''
  if ($p -and (Test-Path $p -PathType Leaf)) { $p }
}
$pat = '(/Users/[A-Za-z0-9._-]+/|C:\\Users\\[A-Za-z0-9._-]+\\|GoogleOAuthClient\.json|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36})'
$hits = if ($paths) { Select-String -Path $paths -Pattern $pat -CaseSensitive:$false } else { @() }
Write-Output "FILES_SCANNED=$($paths.Count) HITS=$($hits.Count)"
$hits | ForEach-Object { Write-Output "HIT: $($_.Path):$($_.LineNumber): $($_.Matches[0].Value)" }
```

Also inspect `git diff` to ensure zero external competitor/reference product names, design-tip author names, or untracked root scratch files are introduced.

## 3. Build Release x64 NSIS Installer

Build `charkle-cli.exe` sidecar and package `Charkle_<version>_x64-setup.exe` via Tauri v2 NSIS bundler:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build-release-nsis.ps1
```

Record the exact byte size and lowercase SHA-256 of the built installer:

```powershell
$exe = Get-ChildItem 'windows/target/release/bundle/nsis' -Filter 'Charkle_*_x64-setup.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$sha = (Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "FILE=$($exe.Name) SIZE=$($exe.Length) SHA256=$sha"
```

## 4. Safe Local Deployment & Detached Relaunch (`%LOCALAPPDATA%\Charkle\`)

When deploying a fresh Release build locally for interactive user testing:

1. Gracefully stop running `charkle-desktop` / `charkle-cli` processes so binary copy never fails with file-lock errors.
2. Copy `windows/target/release/charkle-desktop.exe` and `windows/target/release/charkle-cli.exe` into `%LOCALAPPDATA%\Charkle\` and verify SHA-256 parity.
3. **Always launch detached via `Win32_Process`** (never bare execution or synchronous child launch inside an ephemeral shell, which terminates or hangs when the command shell exits):

```powershell
$ErrorActionPreference = 'Stop'
Get-Process -Name 'charkle-desktop','charkle-cli' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

$dest = Join-Path $env:LOCALAPPDATA 'Charkle'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Force 'windows/target/release/charkle-desktop.exe' (Join-Path $dest 'charkle-desktop.exe')
Copy-Item -Force 'windows/target/release/charkle-cli.exe' (Join-Path $dest 'charkle-cli.exe')

$srcHash = (Get-FileHash 'windows/target/release/charkle-desktop.exe' -Algorithm SHA256).Hash
$dstHash = (Get-FileHash (Join-Path $dest 'charkle-desktop.exe') -Algorithm SHA256).Hash
if ($srcHash -ne $dstHash) { throw 'Deployed binary SHA-256 mismatch!' }

$res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
  CommandLine = (Join-Path $dest 'charkle-desktop.exe')
}
if ($res.ReturnValue -ne 0) { throw "Win32_Process Create failed: $($res.ReturnValue)" }
Get-Process -Id $res.ProcessId | Select-Object Id, ProcessName, CPU, WorkingSet64
```

## 5. Concurrent `origin/main` Rebase Sync & Explicit Push

macOS and Web sessions may push to `origin/main` concurrently while Windows builds. Always sync cleanly before pushing:

1. Run `git fetch origin` and check `git rev-list --count HEAD..origin/main` plus `git diff --name-only HEAD..origin/main`.
2. Inspect `git status -uall --short` and stage **only** intended Windows/shared files explicitly (never stage untracked scratch files or unrelated platform directories).
3. Commit cleanly, then run `git rebase origin/main`. If any upstream commit modified files under `windows/`, re-run Step 1 before pushing.
4. Push **explicit refs only** (never run `git push --all` or `git push --mirror`):

```powershell
git push origin main
```

## 6. Coordinated Dual-Platform GitHub Release Update (`vX.Y.Z`)

macOS and Windows share a single `vX.Y.Z` GitHub Release. Wait for user confirmation after live testing before publishing (unless explicitly instructed to publish immediately).

1. **Fetch the live Release metadata first** (never overwrite Release notes from a stale local draft — macOS may have updated its DMG or notes):
   ```powershell
   gh release view vX.Y.Z --json tagName,name,isDraft,url,assets,body > release-current.json
   ```
2. **Upload or hot-replace only the Windows installer** with `--clobber`:
   ```powershell
   gh release upload vX.Y.Z "windows/target/release/bundle/nsis/Charkle_X.Y.Z_x64-setup.exe" --clobber
   ```
3. **Surgically update Release notes while verifying macOS notes are untouched**:
   - Preserve the entire `## macOS` section 100% character-for-character verbatim.
   - Replace the `## Windows` placeholder (or previous Windows block) with updated Windows notes, binary size, Windows 10/11 `x64` requirements, and exact lowercase SHA-256.
   - Audit for zero personal paths, secrets, placeholders, or external reference/competitor/author names, programmatically assert the live `## macOS` substring is contained verbatim in the new notes file, then apply:
   ```powershell
   gh release edit vX.Y.Z --notes-file "<updated_notes_file>"
   ```
4. **Verify the published Release**:
   ```powershell
   gh release view vX.Y.Z --json tagName,name,isDraft,url,assets,body
   ```
   Confirm both `Charkle-X.Y.Z-arm64.dmg` and `Charkle_X.Y.Z_x64-setup.exe` are `uploaded`, GitHub's `digest` (`sha256:...`) matches the local installer SHA-256, and both platform sections render cleanly.

---
name: charkle-macos-ship
description: >-
  Run Charkle's verified macOS pre-ship and release pipeline: strict zero-warning Swift build
  and tests (plus browser extension and Figma plugin checks), Python-based repository purity
  and secret audit, signed Release .app and .dmg packaging, clean /tmp strict codesign
  verification for both Charkle.app and CharkleSafariExtension.appex, race-free relaunch with
  settled idle CPU check, concurrent origin/main rebase sync with explicit Git push, and
  coordinated dual-platform GitHub Release publishing or non-destructive DMG hot-replacement.
  Use when finishing, verifying, packaging, releasing, or hot-replacing macOS builds in the
  Charkle repository.
---

# Charkle macOS Verify & Ship Runbook

Follow these steps in order whenever verifying, packaging, pushing, or releasing macOS changes in Charkle.

## 1. Strict Zero-Warning Build & Full Test Suite

Run strict compilation and Swift tests before packaging:

```bash
swift build --build-tests -Xswiftc -warnings-as-errors && swift test --skip-build
```

When cutting a release or modifying browser extension / Figma bridge code, also run:

```bash
node Resources/BrowserExtension/tests/extension.test.mjs && node scripts/test-figma-plugin.cjs
```

Confirm 0 warnings and all suites pass before proceeding.

## 2. Python Purity & Privacy Audit

Do **not** rely on macOS BSD `git grep -E` with `\b` (BSD ERE does not support `\b` word boundaries and will silently miss matches). Always audit changed files with Python `re`:

```bash
python3 - <<'PY'
import pathlib, re, subprocess

changed = subprocess.check_output(
    ["git", "status", "--porcelain"], text=True
).splitlines()
paths = []
for line in changed:
    p = line[3:].strip().split(" -> ")[-1]
    if p and pathlib.Path(p).is_file() and not p.startswith("Charkle"):
        paths.append(p)

# Check personal absolute paths, leaked credentials, or forbidden patterns
pat = re.compile(r"(/Users/[A-Za-z0-9._-]+/|GoogleOAuthClient\.json|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36})", re.I)
hits = []
for f in paths:
    for idx, text in enumerate(pathlib.Path(f).read_text(errors="replace").splitlines(), 1):
        m = pat.search(text)
        if m:
            hits.append((f, idx, m.group(0)))

print(f"FILES_SCANNED={len(paths)} HITS={len(hits)}")
for h in hits:
    print("HIT:", h)
PY
```

Also review `git diff` to ensure zero external reference/competitor/author mentions were introduced.

## 3. Build Signed Release Bundle or Release DMG

Never print signing certificate CN or email.

- **Local verification build (`dist/Charkle.app` only)**:
  ```bash
  ./scripts/build-app.sh release
  ```
- **Release build (`dist/Charkle.app` + `dist/Charkle-<version>-arm64.dmg`)**:
  ```bash
  ./scripts/build-dmg.sh --rebuild
  ```
  Record the final DMG byte size and SHA-256 (`stat -f%z` and `shasum -a 256`).

## 4. Clean `/tmp` Strict Codesign Check & Race-Free Relaunch

Because iCloud-synced `~/Documents` can attach `com.apple.fileprovider.fpfs#P` extended attributes that cause false `codesign --verify` failures, verify **both** `Charkle.app` and its embedded `CharkleSafariExtension.appex` on an xattr-stripped `/tmp` copy. Gracefully quit the old app and wait for PID exit before launching the new bundle so LaunchServices never hits error `-600` (`procNotFound`):

```bash
set -euo pipefail
TMP_VERIFY="$(mktemp -d /tmp/charkle-verify.XXXXXX)"
trap 'rm -rf "$TMP_VERIFY"' EXIT
ditto --norsrc --noextattr dist/Charkle.app "$TMP_VERIFY/Charkle.app"
xattr -cr "$TMP_VERIFY/Charkle.app"
codesign --verify --deep --strict "$TMP_VERIFY/Charkle.app" && echo "CODESIGN_APP_STRICT=OK"
codesign --verify --deep --strict "$TMP_VERIFY/Charkle.app/Contents/PlugIns/CharkleSafariExtension.appex" && echo "CODESIGN_APPEX_STRICT=OK"

if pgrep -x Charkle >/dev/null 2>&1; then
  osascript -e 'tell application id "com.charkle.app" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    pgrep -x Charkle >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -x Charkle >/dev/null 2>&1; then
    pkill -TERM -x Charkle || true
    for _ in $(seq 1 15); do
      pgrep -x Charkle >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi
fi

open -n "$PWD/dist/Charkle.app" && echo "APP_RELAUNCHED=OK"
```

## 5. Settled Idle CPU & Binary Freshness Verification

After the app has run for ~15–30 seconds (do not use shell `sleep` polling loops; run other steps or check once settled), verify the running binary path, timestamp, and idle CPU (`< 1%`):

```bash
ps -axo pid,lstart,pcpu,rss,etime,comm | awk '/Charkle\.app\/Contents\/MacOS\/Charkle$/ {print}'
stat -f "dist binary mtime: %Sm" dist/Charkle.app/Contents/MacOS/Charkle
```

## 6. Concurrent `origin/main` Sync & Explicit Push Discipline

Windows and Web sessions may push to `origin/main` while macOS is building. Always sync cleanly before pushing or tagging:

1. Run `git fetch origin` and check `git rev-list --count HEAD..origin/main` plus `git diff --name-only HEAD..origin/main`.
2. Inspect `git status -uall --short` and stage **only** intended paths explicitly (keep untracked root `Charkle*.svg` untouched; do not accidentally commit edits in `./web/` or `./windows/` during macOS-only tasks).
3. Commit cleanly, then run `git rebase origin/main`. If any upstream commit touched macOS files (`Sources/`, `Tests/`, `Resources/`, `Package.swift`, `scripts/`), re-run Step 1 before pushing.
4. Push **explicit refs only** (never run `git push --all` or `git push --mirror`):

```bash
git push origin main
# For a new version release, create an annotated tag and push it explicitly:
git tag -a vX.Y.Z -m "Charkle vX.Y.Z"
git push origin vX.Y.Z
```

## 7. Coordinated Dual-Platform GitHub Release & Safe DMG Hot-Replacement

macOS and Windows share a single `vX.Y.Z` GitHub Release. Audit all release notes for zero external reference/competitor/author names, zero signing cert identities/CN/emails, and zero personal paths.

- **Publishing a new shared release (macOS first, Windows appends later)**:
  Structure the release notes with clear platform headings (`## macOS（vX.Y.Z · Build N · Apple Silicon）` including the DMG size and SHA-256, followed by a `## Windows（vX.Y.Z）` placeholder block), then publish:
  ```bash
  gh release create vX.Y.Z dist/Charkle-X.Y.Z-arm64.dmg \
    --title "Charkle vX.Y.Z" \
    --notes-file "<notes_file>"
  ```
- **Hot-replacing a macOS DMG on an already-published shared release**:
  1. Overwrite only the macOS asset with `--clobber`:
     ```bash
     gh release upload vX.Y.Z dist/Charkle-X.Y.Z-arm64.dmg --clobber
     ```
  2. **Never overwrite the full release body from a stale local draft** (Windows may have already appended its installer notes). Fetch the live body via `gh release view vX.Y.Z --json body --jq '.body'`, surgically patch only the macOS SHA-256 / macOS bullet lines, write to a temporary notes file, and run `gh release edit vX.Y.Z --notes-file "<updated_notes_file>"`.
  3. Verify the uploaded asset name, byte size, and `updatedAt` with `gh release view vX.Y.Z --json url,tagName,assets`.

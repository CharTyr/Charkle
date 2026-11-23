---
name: charkle-macos-ship
description: >-
  Run Charkle's verified macOS pre-ship pipeline: strict zero-warning Swift build and tests,
  Python-based repository purity and secret audit, signed Release .app bundle packaging,
  clean /tmp strict codesign verification, race-free relaunch with settled idle CPU check,
  and explicit main-branch Git push. Use when finishing, verifying, packaging, or shipping
  macOS changes in the Charkle repository.
---

# Charkle macOS Verify & Ship Runbook

Follow these steps in order whenever verifying, packaging, or pushing macOS changes in Charkle.

## 1. Strict Zero-Warning Build & Full Test Suite

Run strict compilation and tests before packaging:

```bash
swift build --build-tests -Xswiftc -warnings-as-errors && swift test --skip-build
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
pat = re.compile(r"(/Users/[A-Za-z0-9._-]+/|GoogleOAuthClient\.json|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY)", re.I)
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

## 3. Build Signed Release App Bundle

Build `dist/Charkle.app` using the project script (never print signing certificate CN or email):

```bash
./scripts/build-app.sh release
```

## 4. Clean `/tmp` Strict Codesign Check & Race-Free Relaunch

Because iCloud-synced `~/Documents` can attach `com.apple.fileprovider.fpfs#P` extended attributes that cause false `codesign --verify` failures, verify on an xattr-stripped `/tmp` copy. Terminate the previous process **before** the `/tmp` verification so LaunchServices never hits error `-600` (`procNotFound`) on relaunch:

```bash
set -euo pipefail
pkill -x Charkle 2>/dev/null || true
TMP_VERIFY="$(mktemp -d /tmp/charkle-verify.XXXXXX)"
trap 'rm -rf "$TMP_VERIFY"' EXIT
cp -RX dist/Charkle.app "$TMP_VERIFY/Charkle.app"
xattr -cr "$TMP_VERIFY/Charkle.app"
codesign --verify --deep --strict "$TMP_VERIFY/Charkle.app" && echo "CODESIGN_STRICT=OK"
open dist/Charkle.app && echo "APP_RELAUNCHED=OK"
```

## 5. Settled Idle CPU & Binary Freshness Verification

After the app has run for ~15–30 seconds (do not use shell `sleep` polling loops; run other steps or check once settled), verify the running binary path, timestamp, and idle CPU (`< 1%`):

```bash
ps -axo pid,lstart,pcpu,rss,etime,comm | awk '/Charkle\.app\/Contents\/MacOS\/Charkle$/ {print}'
stat -f "dist binary mtime: %Sm" dist/Charkle.app/Contents/MacOS/Charkle
```

## 6. Explicit Staging & Push Discipline

- Inspect `git status --short` and stage **only** intended paths (keep untracked `Charkle*.svg` untouched; do not accidentally commit edits in `./web/` or `./windows/` during macOS-only tasks).
- Commit cleanly and push **explicitly**:

```bash
git push origin main
```

Never run `git push --all` or `git push --mirror`.

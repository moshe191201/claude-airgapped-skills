#!/usr/bin/env bash
# Prove the bundle installs with NO network access, before you ship it.
#
# Usage: verify_bundle.sh [bundle-dir]
#
# 1. Verifies every checksum in MANIFEST.sha256.
# 2. Does a throwaway install using forced-offline flags.
# 3. On Linux, re-runs the install inside `unshare -n` (a network namespace with
#    no interfaces) when available — that PHYSICALLY proves zero egress.
#    On macOS, --no-index/--offline are the guarantee (they error instead of
#    falling back to the network).
set -euo pipefail

BUNDLE_DIR="${1:-./airgap-bundle}"
BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
[[ -f "$BUNDLE_DIR/MANIFEST.sha256" ]] || { echo "!! No MANIFEST.sha256 — run finalize_bundle.sh first." >&2; exit 1; }

FAIL=0

echo ">> [1/3] Verifying checksums ..."
(
  cd "$BUNDLE_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c MANIFEST.sha256 --quiet
  else
    shasum -a 256 -c MANIFEST.sha256 >/dev/null
  fi
) && echo "     checksums OK" || { echo "!! checksum verification FAILED" >&2; FAIL=1; }

# Detect a network-isolation wrapper (Linux only).
NETNS=()
if command -v unshare >/dev/null 2>&1 && unshare -rn true >/dev/null 2>&1; then
  NETNS=(unshare -rn)
  echo ">> Network-namespace isolation available — installs will run with zero interfaces."
else
  echo ">> No usable 'unshare -n' (expected on macOS); relying on --no-index/--offline."
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -d "$BUNDLE_DIR/python/wheelhouse" ]]; then
  echo ">> [2/3] Test-installing Python deps offline ..."
  if ${NETNS[@]+"${NETNS[@]}"} bash -c '
      set -e
      python3 -m venv "'"$WORK"'/venv"
      "'"$WORK"'/venv/bin/pip" install --no-index --find-links "'"$BUNDLE_DIR"'/python/wheelhouse" \
          -r "'"$BUNDLE_DIR"'/python/requirements.txt" >/dev/null
  '; then
    echo "     Python offline install OK"
  else
    echo "!! Python offline install FAILED" >&2; FAIL=1
  fi
else
  echo ">> [2/3] No python/ in bundle — skipping."
fi

if [[ -d "$BUNDLE_DIR/node/npm-cache" ]]; then
  echo ">> [3/3] Test-installing Node deps offline ..."
  cp "$BUNDLE_DIR/node/package.json" "$BUNDLE_DIR/node/package-lock.json" "$WORK/" 2>/dev/null || true
  if ${NETNS[@]+"${NETNS[@]}"} bash -c '
      set -e
      cd "'"$WORK"'"
      npm ci --offline --cache "'"$BUNDLE_DIR"'/node/npm-cache" --ignore-scripts >/dev/null 2>&1
  '; then
    echo "     Node offline install OK"
  else
    echo "!! Node offline install FAILED" >&2; FAIL=1
  fi
else
  echo ">> [3/3] No node/ in bundle — skipping."
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  if [[ ${#NETNS[@]} -gt 0 ]]; then
    echo ">> VERIFIED: bundle installs with zero network access (network-namespace isolated)."
  else
    echo ">> VERIFIED: bundle installs with forced-offline flags (no network fallback possible)."
  fi
  exit 0
else
  echo ">> VERIFICATION FAILED — do not ship. See errors above and references/troubleshooting.md." >&2
  exit 1
fi

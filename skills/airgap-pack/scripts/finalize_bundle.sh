#!/usr/bin/env bash
# Finalize an offline bundle: write the target-side install.sh, an operator
# README, and a checksum manifest over everything in the bundle.
#
# Usage: finalize_bundle.sh [bundle-dir]
set -euo pipefail

BUNDLE_DIR="${1:-./airgap-bundle}"
[[ -d "$BUNDLE_DIR" ]] || { echo "!! No such bundle dir: $BUNDLE_DIR" >&2; exit 1; }

HAS_PY=no;  [[ -d "$BUNDLE_DIR/python/wheelhouse" ]] && HAS_PY=yes
HAS_NODE=no; [[ -d "$BUNDLE_DIR/node/npm-cache"   ]] && HAS_NODE=yes

if [[ "$HAS_PY" == no && "$HAS_NODE" == no ]]; then
  echo "!! Bundle has neither python/ nor node/ — run a pack step first." >&2
  exit 1
fi

# --- target-side installer --------------------------------------------------
# Forced-offline flags (pip --no-index, npm --offline) make any network attempt
# an ERROR rather than a silent fallback. That is the air-gap guarantee.
cat > "$BUNDLE_DIR/install.sh" <<'INSTALL'
#!/usr/bin/env bash
# Offline installer — run this on the AIR-GAPPED machine. No network required.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Verifying bundle integrity ..."
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$HERE" && sha256sum -c MANIFEST.sha256 --quiet)
elif command -v shasum >/dev/null 2>&1; then
  (cd "$HERE" && shasum -a 256 -c MANIFEST.sha256)
else
  echo "   (no sha256 tool found; skipping integrity check)"
fi

if [[ -d "$HERE/python/wheelhouse" ]]; then
  echo ">> Installing Python dependencies (offline) ..."
  VENV="${AIRGAP_VENV:-$HERE/venv}"
  python3 -m venv "$VENV"
  # Upgrade the toolchain from the vendored wheels first, then the project deps.
  "$VENV/bin/pip" install --no-index --find-links "$HERE/python/wheelhouse" \
      pip setuptools wheel || true
  "$VENV/bin/pip" install --no-index --find-links "$HERE/python/wheelhouse" \
      -r "$HERE/python/requirements.txt"
  echo "   Python env ready at: $VENV"
fi

if [[ -d "$HERE/node/npm-cache" ]]; then
  echo ">> Installing Node dependencies (offline) ..."
  TARGET="${AIRGAP_NODE_DIR:-$HERE/node}"
  # package.json + package-lock.json already sit in $HERE/node alongside the cache.
  ( cd "$TARGET" && npm ci --offline --cache "$HERE/node/npm-cache" )
  echo "   node_modules ready in: $TARGET"
  echo "   (Copy node/node_modules next to your app, or set the app's working dir here.)"
fi

echo ">> Offline install complete."
INSTALL
chmod +x "$BUNDLE_DIR/install.sh"

# --- operator README --------------------------------------------------------
cat > "$BUNDLE_DIR/README.md" <<README
# Air-gapped install bundle

Self-contained dependency bundle. Installs with **no network access**.

## Contents
$( [[ "$HAS_PY"   == yes ]] && echo "- \`python/wheelhouse/\` — all pip dependencies (wheels/sdists) + \`requirements.txt\`" )
$( [[ "$HAS_NODE" == yes ]] && echo "- \`node/npm-cache/\` — offline npm cache + \`package.json\` / \`package-lock.json\`" )
- \`install.sh\` — run this on the air-gapped machine
- \`MANIFEST.sha256\` — integrity checksums

## Install
\`\`\`bash
./install.sh
\`\`\`

The installer verifies checksums, then installs using forced-offline flags
(\`pip --no-index\`, \`npm ci --offline\`). If anything tries to reach the network
the install fails loudly rather than silently — that is intended.

## Requirements on the target
$( [[ "$HAS_PY"   == yes ]] && echo "- Python 3 with the \`venv\` module (standard library)" )
$( [[ "$HAS_NODE" == yes ]] && echo "- Node.js + npm (same major version family as the build machine)" )
README

# --- checksum manifest (last, so it covers install.sh + README) -------------
echo ">> Writing MANIFEST.sha256 ..."
(
  cd "$BUNDLE_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256
  elif command -v shasum >/dev/null 2>&1; then
    find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 shasum -a 256 > MANIFEST.sha256
  else
    echo "!! No sha256sum/shasum available — cannot write manifest." >&2
    exit 1
  fi
)

FILES=$(grep -c . "$BUNDLE_DIR/MANIFEST.sha256" 2>/dev/null || echo 0)
echo ""
echo ">> Bundle finalized: $BUNDLE_DIR"
echo "     install.sh + README.md written, $FILES files checksummed."
du -sh "$BUNDLE_DIR" 2>/dev/null | sed 's/^/     total size: /' || true

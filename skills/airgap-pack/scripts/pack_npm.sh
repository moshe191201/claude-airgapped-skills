#!/usr/bin/env bash
# Vendor all npm dependencies (transitive included) into an offline bundle.
#
# Usage:   pack_npm.sh [project-dir] [bundle-dir]
# Env:
#   NPM_TARGET_OS   cross-download optional/native deps for another OS  (npm 10+), e.g. linux
#   NPM_TARGET_CPU  cross-download for another CPU arch (npm 10+), e.g. x64
#
# Output: <bundle-dir>/node/npm-cache/ (content-addressable) + package.json + lockfile.
# We ship the cache, NOT node_modules: the cache is portable and integrity-checked,
# node_modules is platform-baked and bulky. The target rebuilds it via `npm ci --offline`.
set -euo pipefail

PROJECT_DIR="$(cd "${1:-.}" && pwd)"
BUNDLE_DIR="${2:-./airgap-bundle}"
TARGET_OS="${NPM_TARGET_OS:-}"
TARGET_CPU="${NPM_TARGET_CPU:-}"

# Resolve the bundle to an absolute path: the cache is populated from a temp
# working dir later, so a relative path would resolve against the wrong place.
mkdir -p "$BUNDLE_DIR"
BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
NODE_OUT="$BUNDLE_DIR/node"
CACHE="$NODE_OUT/npm-cache"
mkdir -p "$CACHE"

cd "$PROJECT_DIR"

if [[ ! -f package.json ]]; then
  echo "!! No package.json in $PROJECT_DIR — nothing to pack." >&2
  exit 1
fi

# --- require a lockfile for reproducibility ---------------------------------
if [[ ! -f package-lock.json ]]; then
  echo "!! No package-lock.json found." >&2
  echo "   Without a lockfile the far side can't get the exact versions you tested." >&2
  echo "   Run 'npm install --package-lock-only' to generate one, then re-run." >&2
  echo "   See references/troubleshooting.md." >&2
  exit 1
fi

cp package.json "$NODE_OUT/package.json"
cp package-lock.json "$NODE_OUT/package-lock.json"

# --- cross-platform optional/native deps ------------------------------------
XPLAT_ARGS=()
if [[ -n "$TARGET_OS" || -n "$TARGET_CPU" ]]; then
  [[ -n "$TARGET_OS"  ]] && XPLAT_ARGS+=(--os="$TARGET_OS")
  [[ -n "$TARGET_CPU" ]] && XPLAT_ARGS+=(--cpu="$TARGET_CPU")
  echo ">> Cross-downloading optional/native deps for os=${TARGET_OS:-current} cpu=${TARGET_CPU:-current}"
  echo "   (requires npm 10+; verify the target binaries landed in the cache)"
fi

# --- populate the cache with every tarball in the lockfile ------------------
# `npm ci` against an explicit --cache downloads all tarballs into it as a side
# effect. We do it in a temp working tree so we don't disturb the user's
# node_modules, then keep only the cache.
echo ">> Populating offline npm cache at $CACHE ..."
TMP_INSTALL="$(mktemp -d)"
trap 'rm -rf "$TMP_INSTALL"' EXIT
cp package.json package-lock.json "$TMP_INSTALL/"
(
  cd "$TMP_INSTALL"
  # --ignore-scripts: don't run install hooks during *packing* — they belong on
  # the target. This also avoids native builds against the build machine.
  npm ci --cache "$CACHE" --ignore-scripts ${XPLAT_ARGS[@]+"${XPLAT_ARGS[@]}"}
)

# --- flag install hooks that may fetch binaries outside the registry --------
echo ">> Scanning for install/postinstall hooks (offline traps) ..."
HOOKS="$(node -e '
  const fs=require("fs");
  const lock=JSON.parse(fs.readFileSync("package-lock.json","utf8"));
  const pkgs=lock.packages||{};
  const hits=[];
  for (const [p,info] of Object.entries(pkgs)) {
    if (!info || !info.hasInstallScript) continue;
    hits.push(p.replace(/^node_modules\//,"") || "(root)");
  }
  process.stdout.write(hits.join("\n"));
' 2>/dev/null || true)"

if [[ -n "$HOOKS" ]]; then
  echo ""
  echo "!! Packages with install scripts (may compile or download binaries offline):"
  echo "$HOOKS" | sed 's/^/     /'
  echo "   Native builds (node-gyp) need a compiler + headers on the target."
  echo "   Binary fetchers (puppeteer, playwright, esbuild, etc.) need their"
  echo "   artifacts staged into the bundle. See step 4 in SKILL.md and"
  echo "   references/troubleshooting.md."
fi

echo ""
echo ">> npm pack complete: cache at $CACHE"
du -sh "$CACHE" 2>/dev/null | sed 's/^/     size: /' || true

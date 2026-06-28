#!/usr/bin/env bash
# Vendor all Python/pip dependencies (transitive included) into an offline bundle.
#
# Usage:   pack_pip.sh [project-dir] [bundle-dir]
# Env:
#   REQ_FILE              explicit requirements file (else auto-detect / freeze)
#   PIP_TARGET_PLATFORM   cross-download for another platform, e.g. manylinux2014_x86_64
#   PIP_TARGET_PYVERSION  target python version digits, e.g. 311  (required with PLATFORM)
#
# Output: <bundle-dir>/python/wheelhouse/  + resolved requirements + bootstrap pip.
set -euo pipefail

PROJECT_DIR="$(cd "${1:-.}" && pwd)"
BUNDLE_DIR="${2:-./airgap-bundle}"
REQ_FILE="${REQ_FILE:-}"
PLATFORM="${PIP_TARGET_PLATFORM:-}"
PYVER="${PIP_TARGET_PYVERSION:-}"

# Resolve the bundle to an absolute path so output lands correctly regardless of
# the project dir we cd into below.
mkdir -p "$BUNDLE_DIR"
BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
PY_OUT="$BUNDLE_DIR/python"
WHEELHOUSE="$PY_OUT/wheelhouse"
mkdir -p "$WHEELHOUSE"

cd "$PROJECT_DIR"

# --- resolve a requirements file -------------------------------------------
RESOLVED_REQ="$PY_OUT/requirements.txt"
if [[ -n "$REQ_FILE" ]]; then
  cp "$REQ_FILE" "$RESOLVED_REQ"
  echo ">> Using requirements file: $REQ_FILE"
elif [[ -f requirements.txt ]]; then
  cp requirements.txt "$RESOLVED_REQ"
  echo ">> Using requirements.txt"
elif python -c 'import sys; sys.exit(0)' 2>/dev/null && pip freeze 2>/dev/null | grep -q .; then
  echo ">> No requirements file found; freezing the active environment."
  echo "   (If this isn't the project's env, pass REQ_FILE=... instead.)"
  pip freeze > "$RESOLVED_REQ"
else
  echo "!! No requirements.txt and no usable environment to freeze." >&2
  echo "   Generate one first (e.g. 'pip freeze > requirements.txt' or pip-compile)," >&2
  echo "   then re-run. See references/troubleshooting.md." >&2
  exit 1
fi

# --- build platform flags ---------------------------------------------------
PLATFORM_ARGS=()
if [[ -n "$PLATFORM" ]]; then
  if [[ -z "$PYVER" ]]; then
    echo "!! PIP_TARGET_PLATFORM set but PIP_TARGET_PYVERSION is empty." >&2
    echo "   Cross-platform downloads need both. See references/troubleshooting.md." >&2
    exit 1
  fi
  # Cross-platform requires wheels only; sdists would build for the wrong arch.
  PLATFORM_ARGS=(--platform "$PLATFORM" --python-version "$PYVER" --only-binary=:all:)
  echo ">> Cross-downloading for platform=$PLATFORM python=$PYVER (wheels only)."
else
  echo ">> Building for the current platform: $(python -c 'import platform;print(platform.platform())' 2>/dev/null || echo unknown)"
fi

# --- download project deps --------------------------------------------------
echo ">> Downloading dependencies into $WHEELHOUSE ..."
pip download -r "$RESOLVED_REQ" -d "$WHEELHOUSE" ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"}

# --- vendor the installer toolchain so the target can bootstrap -------------
# A too-old pip on the target can't install some modern wheels; ship our own.
echo ">> Vendoring pip / setuptools / wheel for bootstrap ..."
if [[ ${#PLATFORM_ARGS[@]} -gt 0 ]]; then
  pip download pip setuptools wheel -d "$WHEELHOUSE" ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} || \
    echo "   (warning: could not cross-download toolchain wheels; target pip must suffice)"
else
  pip download pip setuptools wheel -d "$WHEELHOUSE"
fi

# --- flag packages that fetch artifacts outside pip at install/runtime ------
RISKY='playwright|selenium|webdriver-manager|pyppeteer|nltk|spacy|torch|tensorflow|en-core-web'
if grep -iE "$RISKY" "$RESOLVED_REQ" >/dev/null 2>&1; then
  echo ""
  echo "!! Potential offline traps detected in requirements:"
  grep -iE "$RISKY" "$RESOLVED_REQ" | sed 's/^/     /'
  echo "   These may download browsers/models/data on install or first run."
  echo "   See step 4 in SKILL.md and references/troubleshooting.md."
fi

COUNT=$(find "$WHEELHOUSE" -type f \( -name '*.whl' -o -name '*.tar.gz' -o -name '*.zip' \) | wc -l | tr -d ' ')
echo ""
echo ">> pip pack complete: $COUNT artifacts in $WHEELHOUSE"

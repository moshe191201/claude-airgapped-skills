---
name: airgap-pack
description: >-
  Package a Python (pip) and/or Node (npm) project so it can be transferred into
  and installed inside an air-gapped environment with zero network access. Use
  this whenever the user wants to "vendor dependencies", "bundle for offline",
  "prepare for air-gapped / no-internet / isolated / on-prem / classified /
  disconnected deployment", build an "offline installer", create a "transfer
  bundle", or make a project installable without hitting PyPI or the npm
  registry. Trigger even if the user only says "make this runnable on a machine
  with no internet" or "they can't reach pip/npm over there" — this skill covers
  detecting the ecosystem, downloading every transitive dependency, producing a
  checksummed transfer bundle plus an offline install script, and proving the
  install works with networking disabled.
---

# airgap-pack

Package a project so every dependency travels *with* it and installs on the far
side of an air gap — no PyPI, no npm registry, no internet at all.

The core problem: on a normal machine `pip install` and `npm ci` quietly reach
out to the network. Inside an air gap those calls fail and the install dies
halfway. The fix is to **pre-fetch everything on a connected build machine**,
bundle it with checksums and an install script that is *forced* to stay offline,
and **verify the offline install before you ship** — so the failure surfaces on
your desk, not on a machine you can no longer reach.

Scope: **pip (Python)** and **npm (Node)** only. Containers are out of scope.

## The workflow

Work through these phases in order. Each script is in `scripts/` and is safe to
read before running.

### 1. Detect what you're packaging

Look at the project root for:

- **Python** — `requirements.txt`, `pyproject.toml`, `setup.py`, `Pipfile`, or a
  populated virtualenv.
- **Node** — `package.json` plus a lockfile (`package-lock.json`).

A project can be both. Run the matching pack step for each. If you find a
manifest but no lockfile, say so — an unlocked dependency tree means you can't
guarantee the far side gets the same versions you tested (see
`references/troubleshooting.md`).

### 2. Pin the target platform — this is the most common failure

Compiled wheels and npm's native/optional packages (e.g. `esbuild`, `rollup`,
`@swc/core`, anything with `node-gyp`) are **specific to an OS and CPU
architecture**. A bundle built on macOS arm64 will not install on Linux x86_64.

Before vendoring, confirm with the user: **what OS and architecture is the
air-gapped machine?** If it matches the build machine, the defaults are fine. If
not, you must cross-download for the target — pass the platform flags described
in the pip and npm sections below, and read the cross-platform notes in
`references/troubleshooting.md`.

Never assume same-platform silently. A wrong-platform bundle looks perfect until
it lands on the target and fails to import a binary module.

### 3. Vendor dependencies

Run whichever apply. Both write into a shared bundle directory (default
`./airgap-bundle`).

**Python:**
```bash
scripts/pack_pip.sh <project-dir> <bundle-dir>
```
Downloads every transitive dependency as wheels (and sdists where no wheel
exists) into `<bundle-dir>/python/wheelhouse/`, copies the resolved
requirements, and vendors `pip`/`setuptools`/`wheel` so the target can bootstrap
even if its pip is too old. Env vars for cross-platform builds:
`PIP_TARGET_PLATFORM` (e.g. `manylinux2014_x86_64`), `PIP_TARGET_PYVERSION`
(e.g. `311`), `REQ_FILE` to point at a specific requirements file.

**Node:**
```bash
scripts/pack_npm.sh <project-dir> <bundle-dir>
```
Populates a content-addressable npm cache at `<bundle-dir>/node/npm-cache/` that
holds every tarball in the lockfile, copies `package.json` + `package-lock.json`,
and scans for `postinstall`/`install` scripts that fetch binaries from outside
the registry (the classic offline trap — see below). For cross-platform builds
set `NPM_TARGET_OS` and `NPM_TARGET_CPU` (npm 10+).

### 4. Watch for dependencies that won't survive the air gap

Some packages fetch extra binaries *outside* the package manager during install
— Puppeteer downloads Chromium, Playwright downloads browsers, `node-gyp`
compiles against system headers, some Python packages pull data files on first
run. The pack scripts flag the obvious cases, but think about it:

- If a flagged package is **not actually needed** at runtime, propose removing it
  or replacing it with a pure-Python / pure-JS alternative — that's usually the
  cleanest fix.
- If it **is** needed, the extra artifact has to be staged into the bundle
  manually and the install script taught to point at it (e.g.
  `PUPPETEER_SKIP_DOWNLOAD=1` plus a pre-placed Chromium, or
  `PLAYWRIGHT_BROWSERS_PATH`). `references/troubleshooting.md` has the recipes.

Surface these to the user explicitly. A silent "it packed fine" that later fails
offline is the exact outcome this skill exists to prevent.

### 5. Finalize the bundle

```bash
scripts/finalize_bundle.sh <bundle-dir>
```
Writes three things into the bundle:
- `MANIFEST.sha256` — checksum of every file, so the target can prove nothing was
  corrupted or tampered with in transit.
- `install.sh` — the **target-side** installer. It uses `pip --no-index` and
  `npm ci --offline`, which *fail loudly* instead of silently falling back to the
  network — that's what makes the air-gap guarantee real.
- `README.md` — operator instructions for the far side.

### 6. Verify with networking disabled — do not skip this

```bash
scripts/verify_bundle.sh <bundle-dir>
```
Checks every checksum, then does a throwaway install from the bundle alone using
the offline-only flags. On Linux it will additionally run the install inside
`unshare -n` (a network namespace with no interfaces) when available, which
*physically* proves zero egress. On macOS, `--no-index`/`--offline` are the
guarantee, since those flags make any network attempt an error rather than a
fallback.

If verification fails here, it would have failed on the target. Fix it now.
Report the result honestly — "verified offline-installable" only after this
passes.

### 7. Hand off

Tell the user the bundle path, its size, what's inside, and any unresolved
warnings from step 4. The far-side operator transfers the bundle, runs
`./install.sh`, and is done — no network required.

## What to tell the user at the end

Be concrete and honest:
- Which ecosystems were packed and how many packages each.
- The **target platform** the bundle is built for (and a warning if it differs
  from the build machine).
- Any packages that need manual artifact staging (step 4), unresolved.
- Whether offline verification **passed** — and if you couldn't run the
  network-namespace check (e.g. on macOS), say which guarantee you relied on.

## Reference

`references/troubleshooting.md` — cross-platform downloads, native build deps,
binary-fetching postinstall scripts, sdist-only packages, private registries,
and missing-lockfile handling. Read it whenever a pack or verify step warns or
fails.

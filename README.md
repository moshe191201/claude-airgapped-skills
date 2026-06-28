# claude-airgapped-skills

[Claude Code](https://claude.com/claude-code) skills for working in **air-gapped
environments** — machines with no internet access.

## Skills

### `airgap-pack`

Package a Python (pip) and/or Node (npm) project so every dependency travels
*with* it and installs on the far side of an air gap — no PyPI, no npm registry,
no network at all.

The problem it solves: on a normal machine `pip install` and `npm ci` quietly
reach out to the network. Inside an air gap those calls fail and the install dies
halfway. `airgap-pack` pre-fetches everything on a connected build machine,
bundles it with checksums and a forced-offline install script, and **verifies the
offline install before you ship** — so failures surface on your desk, not on a
machine you can no longer reach.

What it does:

1. **Detects** the ecosystems present (pip, npm, or both).
2. **Pins the target platform** — wrong-OS/arch wheels and native modules are the
   #1 air-gap failure, so this is made explicit up front.
3. **Vendors everything**: all transitive deps as a pip wheelhouse + a
   content-addressable npm cache, plus a bootstrap `pip`/`setuptools`/`wheel`.
4. **Flags offline traps**: packages that fetch binaries outside the package
   manager (Puppeteer, Playwright, `node-gyp`, ML models…), with fix recipes.
5. **Finalizes**: a checksummed `MANIFEST.sha256`, a target-side `install.sh`
   (uses `pip --no-index` / `npm ci --offline`, so any network attempt *errors*
   instead of silently falling back), and an operator README.
6. **Verifies offline before shipping** — a throwaway install under forced-offline
   flags, and inside a `unshare -n` network namespace on Linux for physical
   zero-egress proof.

Scope: pip and npm only. Containers are out of scope.

#### Usage

In Claude Code, just ask in natural language — e.g. *"bundle this project for an
air-gapped machine"* — and the skill triggers automatically.

To run the scripts directly:

```bash
SK=skills/airgap-pack/scripts

# 1. Vendor dependencies (run whichever apply)
bash $SK/pack_pip.sh  <project-dir> ./airgap-bundle
bash $SK/pack_npm.sh  <project-dir> ./airgap-bundle

# 2. Write the manifest, install.sh, and README into the bundle
bash $SK/finalize_bundle.sh ./airgap-bundle

# 3. Prove it installs with no network access
bash $SK/verify_bundle.sh ./airgap-bundle
```

Then transfer `airgap-bundle/` to the air-gapped machine and run `./install.sh`.

Cross-platform builds (target OS/arch differs from the build machine):

```bash
# pip
PIP_TARGET_PLATFORM=manylinux2014_x86_64 PIP_TARGET_PYVERSION=311 \
  bash $SK/pack_pip.sh <project-dir> ./airgap-bundle

# npm (npm 10+)
NPM_TARGET_OS=linux NPM_TARGET_CPU=x64 \
  bash $SK/pack_npm.sh <project-dir> ./airgap-bundle
```

See [`skills/airgap-pack/references/troubleshooting.md`](skills/airgap-pack/references/troubleshooting.md)
for cross-platform downloads, sdist-only packages, native modules, binary
fetchers, private registries, and missing-lockfile handling.

## Installing a skill

Copy a skill folder into your Claude Code skills directory:

```bash
cp -R skills/airgap-pack ~/.claude/skills/
```

It then triggers automatically in any Claude Code session when relevant.

## Layout

```
skills/
└── airgap-pack/
    ├── SKILL.md                      # workflow + when to trigger
    ├── references/troubleshooting.md # edge cases and fixes
    └── scripts/
        ├── pack_pip.sh
        ├── pack_npm.sh
        ├── finalize_bundle.sh
        └── verify_bundle.sh
```

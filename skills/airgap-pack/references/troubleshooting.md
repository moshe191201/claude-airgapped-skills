# airgap-pack troubleshooting

Read the section matching the warning or failure you hit.

## Table of contents
- [Cross-platform: build machine ≠ target](#cross-platform)
- [pip: no wheel, only sdist](#pip-sdist)
- [pip: no requirements / unpinned deps](#pip-no-requirements)
- [npm: missing lockfile](#npm-no-lockfile)
- [npm: native modules (node-gyp)](#npm-native)
- [Binary fetchers (Puppeteer, Playwright, browsers, ML models)](#binary-fetchers)
- [Private / internal registries](#private-registry)
- [Verifying true zero-egress](#zero-egress)

---

<a name="cross-platform"></a>
## Cross-platform: build machine ≠ target

The single most common air-gap failure. Wheels (`.whl`) and npm
optional/native packages embed an OS + CPU architecture. Built on macOS arm64,
they will not load on Linux x86_64.

**Find the target's platform** (ask the operator, or run on a same-spec box):
```bash
python3 -c 'import platform; print(platform.platform(), platform.machine())'
node   -e 'console.log(process.platform, process.arch)'
```

**pip** — set both vars before `pack_pip.sh`:
```bash
PIP_TARGET_PLATFORM=manylinux2014_x86_64 PIP_TARGET_PYVERSION=311 \
  scripts/pack_pip.sh . ./airgap-bundle
```
Common platform tags: `manylinux2014_x86_64`, `manylinux2014_aarch64`,
`macosx_11_0_arm64`, `win_amd64`. Cross-download forces `--only-binary=:all:`,
so any sdist-only dependency will error out — see the next section.

**npm** — set the target os/cpu (npm 10+):
```bash
NPM_TARGET_OS=linux NPM_TARGET_CPU=x64 scripts/pack_npm.sh . ./airgap-bundle
```
Then confirm the target-specific optional packages (e.g. `@esbuild/linux-x64`,
`@rollup/rollup-linux-x64-gnu`) actually landed in the cache. If npm resolved
only your host's variant, the most reliable fix is to **run the pack on a machine
that matches the target OS/arch** (a CI runner, a VM).

When in doubt, build on the same OS/arch as the target. It removes a whole class
of "installed fine, crashes at import" failures.

---

<a name="pip-sdist"></a>
## pip: no wheel, only sdist

Some packages publish only source distributions (`.tar.gz`). `pip download` will
grab the sdist, but installing it on the target **compiles from source**, which
needs a C/C++ toolchain and that package's *build* dependencies present offline.

Options, best first:
1. Prefer a version/package that ships a wheel for the target platform.
2. If you control the build machine *and it matches the target*, build the wheel
   yourself so the bundle ships a binary:
   ```bash
   pip wheel <pkg> -w airgap-bundle/python/wheelhouse
   ```
3. If the sdist must build on the target, ensure the target has the compiler and
   headers, and vendor the build backend too (`setuptools`, `wheel`, plus any
   `pyproject.toml` build-system requires) into the wheelhouse.

Cross-platform downloads (`--only-binary=:all:`) refuse sdists entirely — a hard
error here means that dependency has no wheel for your target.

---

<a name="pip-no-requirements"></a>
## pip: no requirements / unpinned deps

`pack_pip.sh` needs a concrete dependency list. If there's no `requirements.txt`
it freezes the active environment — only correct if that env *is* the project's.

For a clean, fully-pinned set including transitive deps, generate a lock first:
```bash
pip install pip-tools && pip-compile -o requirements.txt   # from pyproject/setup
# or, from a known-good venv:
pip freeze > requirements.txt
```
Unpinned deps (`requests` with no `==`) mean the target could resolve different
versions than you tested — pin before packing.

---

<a name="npm-no-lockfile"></a>
## npm: missing lockfile

Without `package-lock.json`, npm resolves versions at install time — impossible
offline and non-reproducible. Generate one without installing:
```bash
npm install --package-lock-only
```
Commit it, then re-run `pack_npm.sh`.

---

<a name="npm-native"></a>
## npm: native modules (node-gyp)

Packages with C/C++ addons (flagged as "install scripts") compile on install via
`node-gyp`, which needs Python, make, and a C++ compiler **on the target**.

Options:
1. If the package ships prebuilt binaries (`prebuild-install`, `node-pre-gyp`),
   those binaries are usually fetched from GitHub, *not* the npm registry — see
   [binary fetchers](#binary-fetchers).
2. Build on a machine matching the target, then ship the compiled `node_modules`
   for that package alongside the bundle (override the cache-only install for it).
3. Ensure the target has the full build toolchain and let `install.sh` run
   scripts (it skips them by default via the test path; the real `install.sh`
   does run them).

---

<a name="binary-fetchers"></a>
## Binary fetchers (Puppeteer, Playwright, browsers, ML models)

These download large artifacts from outside the package manager, so a normal
vendoring pass misses them. Handle each explicitly:

| Package | What it fetches | Offline approach |
|---|---|---|
| `puppeteer` | Chromium | `PUPPETEER_SKIP_DOWNLOAD=1`; pre-stage Chromium, set `PUPPETEER_EXECUTABLE_PATH` |
| `playwright` | browser builds | stage browsers, set `PLAYWRIGHT_BROWSERS_PATH=<dir>`; run `playwright install` from a local mirror |
| `electron` | Electron binary | set `ELECTRON_OVERRIDE_DIST_PATH` to a pre-staged build |
| `node-sass`/`sharp` | prebuilt binaries | use the platform-matched prebuilt, or build natively on a matching box |
| spaCy / NLTK / HF models | model/data files | download the model artifacts separately and stage them; point the lib at the local path |

General pattern: **download the artifact on the connected machine, place it in
the bundle, and teach `install.sh` (or the app's env) to use the local copy
instead of fetching.** If the package isn't actually needed at runtime, dropping
or replacing it is the cleanest fix — raise that with the user.

---

<a name="private-registry"></a>
## Private / internal registries

If deps come from an internal registry (Artifactory, Nexus, Verdaccio, a private
PyPI), pack from a machine that can reach it — the vendored artifacts are then
self-contained and the target needs no registry at all. Nothing in the bundle
points back at the source registry; `install.sh` only ever reads the local
wheelhouse / cache.

If instead the air-gapped side runs its *own* internal mirror, that's a different
model than this skill (you'd publish to that mirror rather than ship a bundle).
Tell the user which model they're in.

---

<a name="zero-egress"></a>
## Verifying true zero-egress

`verify_bundle.sh` already enforces this two ways:
- Forced-offline flags (`pip --no-index`, `npm ci --offline`) turn any network
  attempt into an error — there is no silent fallback.
- On Linux, the test install runs inside `unshare -n` (a network namespace with
  no interfaces) when available, which makes egress physically impossible.

For an even stronger check on Linux, run the whole verify under a namespace:
```bash
unshare -rn scripts/verify_bundle.sh ./airgap-bundle
```
On macOS there's no lightweight per-process network namespace; the forced-offline
flags are the guarantee. If you need a hardware-level proof there, run the verify
on a Linux box or a VM with the network adapter disabled.

# CI strategy for an OxCaml (5.2.0+ox) project — research report (state: 2026-06-09)

## 1. GitHub-hosted runner labels (free/standard plans, public repos)

Verified against https://docs.github.com/en/actions/reference/runners/github-hosted-runners (fetched today):

| Target | Label to use | Status / specs |
|---|---|---|
| linux x86_64 | `ubuntu-24.04` (= `ubuntu-latest`) | GA. 4 vCPU / 16 GB. `ubuntu-22.04` also available. |
| linux arm64 | `ubuntu-24.04-arm` | GA, free on **public** repos. 4 vCPU / 16 GB. `ubuntu-22.04-arm` also exists. Per the 2026-05-14 changelog (https://github.blog/changelog/2026-05-14-github-actions-upcoming-image-migrations/) GitHub now owns/maintains these arm images (previously Arm Ltd). NOTE: for *private* repos arm64 Linux requires paid larger runners. |
| macOS arm64 | `macos-15` (pin it!) | GA. Apple Silicon (M1), 3 vCPU / 7 GB. **Do not use `macos-latest`**: it starts migrating to macOS 26 on 2026-06-15 (same changelog). `macos-14` begins deprecation 2026-07-06 (unsupported by 2026-11-02, per actions/runner-images releases). |
| macOS x86_64 | `macos-15-intel` | **`macos-13` is retired** (deprecation 2025-09-22, fully retired 2025-12-04; https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/ and https://github.com/actions/runner-images/issues/13046). `macos-15-intel` (4 vCPU / 14 GB, announced in https://github.com/actions/runner-images/issues/13045) is the free Intel option, available until **August 2027**; `macos-26-intel` is also listed in the docs. After Fall 2027 there will be no x86_64 macOS on Actions. (`macos-14-large`/`-15-large` are Intel but paid-only labels.) |
| Windows | — | **Dismissed.** oxcaml.org explicitly: "OxCaml does not yet support Windows; WSL 2 recommended" (https://oxcaml.org/get-oxcaml/), and the `oxcaml-compiler` opam build is sh/autoconf-based. Skip Windows entirely. |

## 2. Provisioning the OxCaml toolchain

### a) opam (RECOMMENDED)

- Official incantation (verified at https://oxcaml.org/get-oxcaml/): `opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default`.
- The ox repo (https://github.com/oxcaml/opam-repository) contains exactly one compiler entry point: `ocaml-variants.5.2.0+ox` (virtual, `flags: compiler`, depends on `oxcaml-compiler`; current build package `oxcaml-compiler.5.2.0minus31`). The opam build script vendors and builds: boot OCaml 5.4.0, dune 3.20.2 bootstrap, menhir 20231231, then `autoconf && ./configure --enable-middle-end=flambda2 --enable-runtime5 --enable-stack-checks --enable-poll-insertion --enable-multidomain --disable-warn-error && make`. It has explicit `os = "macos"` configure branches, so macOS x86_64+arm64 are handled; needs `conf-autoconf`/`conf-which` (preinstalled on ubuntu images; oxcaml's own CI does `brew install autoconf` on macOS — see `/Users/krystian/code/ocaml-swiss-table/oxcaml/.github/workflows/build.yml` line 293).
- The ox repo also carries `dune.3.21.0+ox` etc., so the project's only dep resolves from it.
- **setup-ocaml**: current is `ocaml/setup-ocaml@v3` (v3.6.1, 2026-04-16). It DOES support custom repos (`opam-repositories`, "repositories listed first take priority") and arbitrary compiler packages: I verified in source (`packages/setup-ocaml/src/opam.ts`) that the `ocaml-compiler` input is passed verbatim to `opam switch --no-install --packages=<input> create .` whenever it is not a semver range — so `ocaml-compiler: ocaml-variants.5.2.0+ox` works (use the **full package-name form**; a bare `5.2.0+ox` parses as a semver range and would be resolved against the *default* repo's ocaml-base-compiler list — wrong). oxcaml's own CI uses setup-ocaml@v3 with a custom local repo + custom compiler package on linux x64/arm64 and macOS arm64 (build.yml lines 303–311), which is an existence proof for this pattern.
- **Caching**: built-in and automatic. Verified in `packages/setup-ocaml/src/cache.ts`: it caches the opam root + workspace `_opam` keyed on sha256(platform, OS release, arch, opam version, resolved compiler string, repo URLs, sandbox flag) with prefix `v3-setup-ocaml-opam-`. No time-based expiry; cache is saved in the **main** step right after switch creation (verified in `installer.ts`), so packages installed later in the job are NOT in the opam cache. Two consequences: (1) bake `dune` into the switch invariant via `ocaml-compiler: ocaml-variants.5.2.0+ox,dune` so it's inside the cached switch (mechanically sound per source; flagged as an open question since untested); (2) OS image release bumps rotate the key → periodic cold rebuilds.
- **Wall time**: cold = full compiler bootstrap. Anchors: oxcaml's nix package builds in ~7 min on 8-core WarpBuild runners; full `make ci` jobs take 12–21 min on 8-core (run 27211454921 via GitHub API); oxcaml.org says Codespaces init takes "30+ minutes". Estimate on standard runners: **~35–60 min** (ubuntu 4 vCPU), **~30–50 min** (macos-15 M1), **~50–90 min** (macos-15-intel). All far under the 6 h cap. Warm: cache restore of opam root ≈ **1–3 min**.

### b) nix

- Local flake (`/Users/krystian/code/ocaml-swiss-table/oxcaml/flake.nix`) uses `flake-utils.eachDefaultSystem` → packages defined for x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin; `default.nix` builds patched boot OCaml 5.4.0 + dune 3.20.2 + menhir + ocamlformat overrides from source (no public binary cache has these).
- Upstream's nix CI (`nix-github-actions.yml`) only exercises **x86_64-linux, aarch64-linux, aarch64-darwin** (flake.nix `getAttrs` lines 63–67) on WarpBuild runners; latest run (27237863215, 2026-06-09) all green, `nix build` steps 5–9 min on 8-core. **x86_64-darwin is never CI-tested upstream.**
- Nix is pinned to **2.33.0** via `cachix/install-nix-action@v31` (latest v31.10.6) because "later versions of nix cause out of memory issues on darwin" (nix-github-actions.yml comment) — you'd need to replicate that pin.
- Installer landscape 2026: `DeterminateSystems/nix-installer-action` (v22) now **always installs Determinate Nix** — upstream-Nix option removed 2026-01-01 (https://determinate.systems/blog/installer-dropping-upstream/). For upstream nix use cachix/install-nix-action.
- Caching: magic-nix-cache was deprecated Feb 2025, later revived on a reverse-engineered cache API (fragile; https://determinate.systems/blog/bringing-back-magic-nix-cache-action/). FlakeHub Cache and cachix both require accounts/tokens (not zero-secret). The practical zero-secret option is `nix-community/cache-nix-action` (v7.0.2) over the Actions cache — but the 10 GiB/repo cache budget is tight for 4 platform store closures, and a cache miss = full toolchain rebuild (~30–90 min/platform; bounded, under 6 h).

### c) Prebuilt binaries / images

**No official ones.** Unofficial: Anil Madhavapeddy's oxcaml-pkgs — native deb/rpm/pacman/brew packages installing `oxcaml-compiler` into `/opt`, one-liner `curl -fsSL https://oi.thicket.dev/repo/install.sh | sh` (https://anil.recoil.org/notes/oxcaml-packages), and `avsm/claude-ocaml-devcontainer` docker images. Third-party trust + unclear coverage of all 4 CI targets → usable as a future accelerator, not the foundation.

## 3. Recommendation: opam via ocaml/setup-ocaml@v3

Zero secrets, all 4 platforms with one uniform step, automatic caching keyed on the toolchain, warm restore in minutes, matches both the documented install path and oxcaml's own CI tooling. Nix is a fine fallback (you've proven aarch64-darwin locally) but loses on: x86_64-darwin untested upstream, the darwin nix-2.33.0 pin, Determinate-only installer churn, and 10 GiB cache pressure for 4 closures.

```yaml
jobs:
  build:
    name: build (${{ matrix.platform }})
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 180          # cold toolchain headroom; hard cap/default is 360 (6 h)
    continue-on-error: ${{ matrix.experimental == true }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - { platform: linux-x86_64,  runner: ubuntu-24.04 }
          - { platform: linux-arm64,   runner: ubuntu-24.04-arm }
          - { platform: macos-arm64,   runner: macos-15 }          # pin: macos-latest -> macOS 26 from 2026-06-15
          - { platform: macos-x86_64,  runner: macos-15-intel,     # label lives until Aug 2027
              experimental: true }     # x86 macOS: "may still work" per oxcaml README; not CI-tested upstream
    steps:
      - uses: actions/checkout@v6   # v6.0.3 current

      - name: Install autoconf (macOS)            # oxcaml's own CI does this; ubuntu images have it
        if: runner.os == 'macOS'
        run: HOMEBREW_NO_INSTALL_CLEANUP=TRUE brew install autoconf

      # Toolchain. Creates local switch ./_opam containing the OxCaml compiler (+ dune,
      # baked into the switch invariant so it lands inside the action's automatic opam cache,
      # which is saved immediately after switch creation).
      # Cache key = v3-setup-ocaml-opam-sha256(platform, os-release, arch, opam-ver,
      #             "ocaml-variants.5.2.0+ox,dune", repo URLs, sandbox)  — no time expiry.
      - name: Set up OxCaml 5.2.0+ox
        uses: ocaml/setup-ocaml@v3                # v3.6.1
        with:
          ocaml-compiler: ocaml-variants.5.2.0+ox,dune
          opam-repositories: |
            ox: git+https://github.com/oxcaml/opam-repository.git
            default: git+https://github.com/ocaml/opam-repository.git
          opam-pin: false
          dune-cache: true        # optional: dune build cache, keyed per workflow/job

      - name: Build and test
        run: |
          opam exec -- dune build
          opam exec -- dune runtest

      - uses: actions/upload-artifact@v7          # v7.0.1; name must be unique per matrix job (v4+ artifacts immutable)
        with:
          name: results-${{ matrix.platform }}
          path: _build/bench-results/

  summarize:
    needs: build
    if: always()
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/download-artifact@v8        # v8.0.1; pattern+merge works across arch jobs
        with:
          pattern: results-*
          merge-multiple: true
          path: results/
      - name: Write summary
        run: ./aggregate results/ >> "$GITHUB_STEP_SUMMARY"   # GFM supported, 1 MiB/step
```

Fallbacks if the invariant trick misbehaves: use `ocaml-compiler: ocaml-variants.5.2.0+ox` + an explicit `opam install dune` step (adds ~2–4 min every run, uncached). If the opam sandbox causes trouble building the compiler, add `opam-disable-sandboxing: true` (oxcaml's CI sets it).

## 4. Misc facts

- Per-job default timeout: **360 min (6 h)**, also the GitHub-hosted hard cap; workflow run max 35 days; Actions cache **10 GiB/repo** (https://docs.github.com/en/actions/reference/limits). Budget: 4 cached opam roots ≈ ~1–2 GiB each compressed — fits, but watch it if dune-cache is on.
- Artifacts: current = `actions/upload-artifact@v7.0.1` and `actions/download-artifact@v8.0.1` (verified via GitHub API). v4 still functions but runs node20: forced to node24 from 2026-06-02, node20 removed from runners 2026-09-16 (https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/) — use v6+. v6 = node24 (needs runner ≥2.327.1, irrelevant on hosted); v7 = ESM + optional `archive: false`. v4+ semantics (immutable artifacts, unique-name-per-matrix-job, `pattern`/`merge-multiple` aggregation) unchanged. `actions/cache` is at v5.0.5; `actions/checkout` at v6.0.3.
- `GITHUB_STEP_SUMMARY`: GitHub-flavored Markdown; 1 MiB per step, max 20 step summaries shown per job; summaries from multiple jobs are displayed on the run page ordered by job completion time (https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/workflow-commands-for-github-actions#adding-a-job-summary) — so you get per-arch summaries for free, plus the artifact-fed aggregation job above for a single combined table.
- Cross-arch artifact aggregation: explicitly supported/documented pattern in download-artifact v8 README.

## 5. Upstream platform-breakage signals

- README (https://raw.githubusercontent.com/oxcaml/oxcaml/main/README.md): "The supported platforms are x86-64 and arm64 Linux; and arm64 macOS. **x86 macOS may still work.**" → treat `macos-15-intel` as experimental/non-blocking.
- Flake `githubActions` matrix exercises only `x86_64-linux`, `aarch64-linux`, `aarch64-darwin` (flake.nix lines 63–72); **x86_64-darwin is defined but never tested**. All three exercised systems are green as of run 27237863215 (2026-06-09).
- Flake checks built per system: `oxcaml`, `oxcaml-fp`, `oxcaml-r5`, `oxcaml-fp-r5`, `oxcaml-asan`, `oxcaml-asan-r5`, filtered by `meta.broken`; default.nix marks **frame-pointer variants broken on non-x86_64** (line 299), so arm systems only build oxcaml/oxcaml-r5(/asan filtering also applies). Latest run confirms: asan+fp variants ran only on x86_64-linux.
- Nix pinned to 2.33.0: "later versions of nix cause out of memory issues on darwin" (nix-github-actions.yml lines 25–27).
- oxcaml.org: musl/Alpine unsupported (glibc only), Windows unsupported, x86_64+arm64 only, no SIMD on ARM.
- macOS quirk in build.yml (lines 362–369): Homebrew autoconf 2.72+ probes C23 and breaks the *runtime4* darwin build (CFLAGS=-std=gnu11 workaround) — the opam package builds runtime5, so this shouldn't bite, but it's a known macOS+autoconf sharp edge.
- oxcaml's entire first-party CI runs on paid WarpBuild runners (warp-ubuntu-latest-x64-8x / -arm64-8x / warp-macos-15-arm64-6x) — no Intel mac anywhere upstream.

## Sources

Local: `/Users/krystian/code/ocaml-swiss-table/oxcaml/.github/workflows/{build,nix-github-actions,coverage,merlin,ocamlformat,document-syntax}.yml`, `/Users/krystian/code/ocaml-swiss-table/oxcaml/flake.nix`, `/Users/krystian/code/ocaml-swiss-table/oxcaml/default.nix`.
Web: [oxcaml.org/get-oxcaml](https://oxcaml.org/get-oxcaml/) · [oxcaml README](https://github.com/oxcaml/oxcaml) · [oxcaml/opam-repository](https://github.com/oxcaml/opam-repository) (ocaml-variants.5.2.0+ox, oxcaml-compiler.5.2.0minus31 opam files via raw.githubusercontent.com) · oxcaml Actions runs 27237863215 / 27211454921 via GitHub REST API · [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) · [Actions limits](https://docs.github.com/en/actions/reference/limits) · [macOS 13 closing down changelog](https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/) · [runner-images #13046](https://github.com/actions/runner-images/issues/13046) / [#13045](https://github.com/actions/runner-images/issues/13045) · [2026-05-14 image migrations changelog](https://github.blog/changelog/2026-05-14-github-actions-upcoming-image-migrations/) · [node20 deprecation changelog](https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/) · [ocaml/setup-ocaml](https://github.com/ocaml/setup-ocaml) (+ raw `action.yml`, `src/cache.ts`, `src/opam.ts`, `src/installer.ts`, `src/version.ts`) · [actions/upload-artifact releases](https://github.com/actions/upload-artifact/releases) · [actions/download-artifact](https://github.com/actions/download-artifact) · [workflow commands / job summary docs](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/workflow-commands-for-github-actions#adding-a-job-summary) · [Determinate installer drops upstream nix](https://determinate.systems/blog/installer-dropping-upstream/) · [Magic Nix Cache revival](https://determinate.systems/blog/bringing-back-magic-nix-cache-action/) · [nix-community/cache-nix-action](https://github.com/nix-community/cache-nix-action) · [oxcaml native packages (oxcaml-pkgs)](https://anil.recoil.org/notes/oxcaml-packages) · [avsm/claude-ocaml-devcontainer](https://github.com/avsm/claude-ocaml-devcontainer)

## Open questions
- Does `ocaml-compiler: ocaml-variants.5.2.0+ox,dune` (dune in the switch invariant) resolve cleanly against the ox repo? Verified mechanically in setup-ocaml source (--packages passed verbatim) but not battle-tested; fallback is a separate `opam install dune` step (~2-4 min every run, never cached because setup-ocaml saves the opam cache before user steps).
- Does oxcaml 5.2.0+ox actually build on macos-15-intel (x86_64-darwin)? Upstream README says 'x86 macOS may still work' and no upstream CI exercises it — the matrix marks it experimental/continue-on-error; needs one empirical run.
- Cold-build wall-time estimates (35-60 min linux 4 vCPU, 30-50 min macos-15 M1, 50-90 min macos-15-intel) are extrapolated from oxcaml's 8-core WarpBuild timings and the '30+ min' Codespaces figure; calibrate timeout-minutes after the first cold runs.
- Is the project repo public? ubuntu-24.04-arm (free arm64 Linux) and unlimited macOS minutes only apply to public repos; private repos need paid arm64 runners and burn macOS minutes at 10x.
- setup-ocaml's opam cache key includes the runner OS release, so runner image updates (every few weeks) silently trigger full cold rebuilds — acceptable, but worth knowing when a 5-minute job suddenly takes an hour.

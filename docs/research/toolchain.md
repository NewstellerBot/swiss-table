# Verified dune build recipe for OxCaml-from-source (no opam switch)

Everything below was actually executed and verified in `/tmp/oxdune` on 2026-06-09. Final state: `dune build`, `dune build @all`, and `dune runtest` all exit 0; the test prints `swisstest OK on OCaml 5.2.0+ox`; the bytecode test prints `bytecode OK on OCaml 5.2.0+ox` when run via `ocamlrun`.

## 1. The toolchain shim (required)

`/Users/krystian/code/ocaml-swiss-table/oxcaml/_build/install/main/bin` ships ONLY `.opt`/`.byte`-suffixed binaries (confirmed: no plain `ocamlc`/`ocamlopt` exist). Dune discovers the toolchain by searching PATH for a binary literally named `ocamlc`, so a symlink dir is mandatory. `ocamlrun` lives in a *different* install tree (`runtime_stdlib_install/bin`). Created with:

```sh
mkdir -p /tmp/oxdune/oxbin
OXBIN=/Users/krystian/code/ocaml-swiss-table/oxcaml/_build/install/main/bin
RTBIN=/Users/krystian/code/ocaml-swiss-table/oxcaml/_build/runtime_stdlib_install/bin
ln -sf $OXBIN/ocamlc.opt       /tmp/oxdune/oxbin/ocamlc
ln -sf $OXBIN/ocamlopt.opt     /tmp/oxdune/oxbin/ocamlopt
ln -sf $OXBIN/ocamldep.opt     /tmp/oxdune/oxbin/ocamldep
ln -sf $OXBIN/ocamlmklib.opt   /tmp/oxdune/oxbin/ocamlmklib
ln -sf $OXBIN/ocamllex.opt     /tmp/oxdune/oxbin/ocamllex
ln -sf $OXBIN/ocamlobjinfo.opt /tmp/oxdune/oxbin/ocamlobjinfo
ln -sf $OXBIN/ocamlyacc        /tmp/oxdune/oxbin/ocamlyacc
ln -sf $OXBIN/ocaml            /tmp/oxdune/oxbin/ocaml
ln -sf $OXBIN/ocamlmktop.opt   /tmp/oxdune/oxbin/ocamlmktop
ln -sf $RTBIN/ocamlrun         /tmp/oxdune/oxbin/ocamlrun
```

(In the verbose build log, dune only ever invoked `ocamlc` 7x and `ocamlopt` 5x — `ocamldep` was never invoked, and zero `.opam` paths appeared in any compile command.)

## 2. Environment — every var and why (`/tmp/oxdune/env.sh`, verified by sourcing it)

```sh
# Source this (sh/zsh/bash) before invoking dune in this project.
#
# 1. PATH: the symlink dir /tmp/oxdune/oxbin MUST come first. dune discovers
#    the toolchain by searching PATH for an executable literally named
#    "ocamlc"; the oxcaml install dir only ships ocamlc.opt / ocamlc.byte,
#    so without the symlinks dune cannot find the compiler at all.
#    We pin the rest of PATH to /usr/bin:/bin so that no opam switch
#    (e.g. ~/.opam/default/bin with vanilla OCaml 5.4.1) can leak in,
#    while still providing clang/cc/ar/etc. for linking.
export PATH=/tmp/oxdune/oxbin:/usr/bin:/bin

# 2. OCAMLLIB: this oxcaml build was configured with a stale prefix
#    (standard_library_default points at a non-existent
#    /Users/krystian/code/testtttttt/...), so the compiler only finds its
#    stdlib when OCAMLLIB points at the real runtime_stdlib_install dir.
#    dune passes its own environment down to the compiler processes it
#    spawns, so exporting it here is sufficient.
export OCAMLLIB=/Users/krystian/code/ocaml-swiss-table/oxcaml/_build/runtime_stdlib_install/lib/ocaml_runtime_stdlib

# 3. OCAMLFIND_CONF: belt-and-suspenders. No ocamlfind is on the PATH above,
#    but if one ever appears, an unreadable conf makes findlib report no
#    packages instead of resolving the 5.4.1 switch libraries.
export OCAMLFIND_CONF=/dev/null

# Convenience: vanilla dune 3.22.2 from the opam switch, invoked by absolute
# path so its bin dir never has to be on PATH.
DUNE=/Users/krystian/.opam/default/bin/dune
```

That is the complete set. No `OCAMLPATH`, no `CAML_LD_LIBRARY_PATH`, no dune-specific vars were needed. The plain (non-nix) shell had no OCaml/opam env vars set and no ocaml tools on PATH, so PATH pinning + OCAMLLIB is sufficient. Dune itself reads `$OCAMLLIB/Makefile.config` when "loading the OCaml compiler for context default" — that file exists in the runtime_stdlib dir, which is why OCAMLLIB must point there.

## 3. Project files (final, verified contents)

`/tmp/oxdune/dune-project`:
```lisp
(lang dune 3.22)
(name oxdune)
```
(`(lang dune 3.22)` is accepted by dune 3.22.2.)

`/tmp/oxdune/lib/dune`:
```lisp
(library
 (name swisstest)
 ; comprehensions is OFF by default (beta universe) -> must pass the flag.
 ; Use (flags ...) so BOTH ocamlc (byte) and ocamlopt (native) get it.
 (flags (:standard -extension comprehensions))
 ; passthrough test: native-only flag; layouts_beta is accepted by ocamlopt
 (ocamlopt_flags (:standard -extension layouts_beta)))
```

`/tmp/oxdune/lib/swisstest.ml`:
```ocaml
(* Proof we are on OxCaml: vanilla OCaml 5.x rejects all of the following. *)

let version = Sys.ocaml_version

(* mode extension (enabled by default): local_ parameter mode annotations *)
let add_local (local_ x) (local_ y) = x + y

(* exclave_ + stack allocation (mode extension, default-on) *)
let stack_pair () = exclave_ (1, 2)

let sum_stack_pair () =
  let (a, b) = stack_pair () in
  a + b

(* immutable array literal (immutable_arrays extension, default-on) *)
let first_iarray =
  match [: 10; 20; 30 :] with
  | [: a; _; _ :] -> a
  | _ -> 0

(* unboxed tuple (layouts, stable universe, default-on) *)
let swap_unboxed () =
  let #(a, b) = #(1, 2) in
  b - a

(* list comprehension: requires -extension comprehensions (beta universe,
   OFF by default) -- proves the dune (flags ...) passthrough works *)
let squares n = [ x * x for x = 1 to n ]
```

`/tmp/oxdune/test/dune`:
```lisp
(test
 (name test_swisstest)
 (modules test_swisstest)
 (libraries swisstest))

; separate bytecode-only executable to verify the byte toolchain works
(executable
 (name test_byte)
 (modules test_byte)
 (modes byte)
 (libraries swisstest))
```

`/tmp/oxdune/test/test_swisstest.ml`:
```ocaml
let () =
  assert (String.equal Swisstest.version "5.2.0+ox");
  (* local_ params: surplus args must go in a separate application *)
  assert ((Swisstest.add_local 2) 3 = 5);
  assert (Swisstest.sum_stack_pair () = 3);
  assert (Swisstest.first_iarray = 10);
  assert (Swisstest.swap_unboxed () = 1);
  assert (Swisstest.squares 4 = [ 1; 4; 9; 16 ]);
  print_endline ("swisstest OK on OCaml " ^ Swisstest.version)
```

`/tmp/oxdune/test/test_byte.ml`:
```ocaml
let () =
  assert (String.equal Swisstest.version "5.2.0+ox");
  assert (Swisstest.squares 3 = [ 1; 4; 9 ]);
  print_endline ("bytecode OK on OCaml " ^ Swisstest.version)
```

## 4. Verified command lines

```sh
cd /tmp/oxdune
source ./env.sh
$DUNE build                 # exit 0
$DUNE build @all            # builds swisstest.{cma,cmxa,cmxs,a}, test_swisstest.exe, test_byte.bc
$DUNE runtest               # prints: swisstest OK on OCaml 5.2.0+ox  (exit 0)
/tmp/oxdune/oxbin/ocamlrun _build/default/test/test_byte.bc
                            # prints: bytecode OK on OCaml 5.2.0+ox  (exit 0)
./_build/default/test/test_swisstest.exe   # Mach-O 64-bit arm64; runs directly, exit 0
```

## 5. Byte vs native status

- **Native: fully works.** `test_swisstest.exe` is a `Mach-O 64-bit executable arm64`, runs directly, `dune runtest` passes. The nix-store assembler/objcopy paths baked into `ocamlc -config` (`/nix/store/iwqkn2hby1qvxai67snyqyw1x8x1m75z-llvm-19.1.7/bin/llvm-mc` and `llvm-objcopy`) exist on disk outside `nix develop`, so native compile+link works from a plain shell — verified, all builds above ran in a plain (non-nix) shell.
- **Byte: compiles and links fine, but `.bc` files cannot be exec'd directly.** `swisstest.cma` and `test_byte.bc` build without error. However the `.bc` shebang embeds the *stale configure prefix*: `file` reports `a /Users/krystian/code/testtttttt/oxcaml/_install/bin/ocamlrun script executable`, and direct execution fails with `bad interpreter: ...testtttttt/...: no such file or directory` (exit 127). Running via explicit `ocamlrun _build/default/test/test_byte.bc` works perfectly. Consequence: keep `(test)` stanzas native (the default when ocamlopt exists); a byte-mode test would fail under `dune runtest` because dune execs the bytecode directly. (Also note `(modes byte)` makes dune produce a `test_byte.exe` copy with the same broken shebang.) The `camlheader` file in the stdlib dir is 0 bytes; the broken path comes from the compiler's built-in default runtime path.

## 6. Extensions in this build (5.2.0+ox)

Full list, obtained via `ocamlopt.opt -extension help` (any invalid value makes the compiler print the accepted set):

`comprehensions mode mode_beta mode_alpha unique unique_beta unique_alpha overwriting include_functor polymorphic_parameters immutable_arrays module_strengthening layouts layouts_beta layouts_alpha simd simd_beta simd_alpha small_numbers small_numbers_beta small_numbers_alpha instances let_mutable layout_poly layout_poly_beta layout_poly_alpha runtime_metaprogramming`

Extension universes: `no_extensions | upstream_compatible | stable | beta | alpha` (`-extension-universe`). Legacy aliases: `-disable-all-extensions` = `no_extensions`, `-only-erasable-extensions` = `upstream_compatible`.

Empirically probed defaults (each compiled with bare `ocamlopt -c`, exit codes checked):
- **ON by default** (default universe behaves exactly like `stable`): `mode` (`local_`, `exclave_`), `immutable_arrays` (`[: ... :]`), `layouts`-stable (unboxed tuples `#(1,2)`, unboxed records `#{ a : int }`), `small_numbers` (`1.0s` float32 literals), `simd` types (`int8x16`).
- **OFF by default**: `comprehensions` (`[ x*x for x = 1 to 5 ]` → `Error: The extension "comprehensions" is disabled and cannot be used`). It is in the **beta** universe: fails under explicit `-extension-universe stable`, passes under `-extension-universe beta` or `-extension comprehensions`.
- Unboxed records failed under `-extension-universe no_extensions` with "requires the stable version of the extension layouts" — confirming the default ≈ stable.

**Dune passthrough verified** via `dune build @all --verbose` after `rm -rf _build`: `-extension comprehensions` from `(flags ...)` appeared on ocamlc compile lines (2 hits) and the native build of comprehension code succeeded; `-extension layouts_beta` from `(ocamlopt_flags ...)` appeared on 3 ocamlopt lines and on **zero** ocamlc lines. Use `(flags ...)` for anything used in code that must build in both modes; `ocamlopt_flags` is native-only.

## 7. Gotchas actually hit

1. **`local_` surplus-application error**: `add_local 2 3` where params are `local_` fails with `This application is complete, but surplus arguments were provided afterwards`. Fix per compiler hint: `(add_local 2) 3`. This is an OxCaml mode-checker behavior you will hit in ordinary-looking code.
2. **Dune env caching: better than feared.** Dune 3.22.2 re-resolves the toolchain on *every* invocation. With a warm `_build`: (a) bogus `OCAMLLIB` → immediate error `Error: /tmp/bogus-no-such-stdlib/Makefile.config: No such file or directory -> required by loading the OCaml compiler for context "default"`; (b) prepending `~/.opam/default/bin` to PATH → dune re-resolved to the 5.4.1 `ocamlc.opt` and failed loudly (`unknown option '-extension'`). Restoring the correct env and rebuilding worked **without** deleting `_build`. So no `rm -rf _build` ritual is required after env changes — BUT note the failure was only loud because the project passes `-extension` flags and uses OxCaml syntax; a plain-OCaml project with a leaked PATH would silently rebuild everything with the wrong compiler. Keep PATH pinned.
3. **Stale configure prefix** (`/Users/krystian/code/testtttttt/...`) surfaces twice: stdlib lookup (fixed by `OCAMLLIB`) and the bytecode shebang (work around with explicit `ocamlrun`).
4. **`ocamlrun` is not in the main install bin dir** — it is only in `runtime_stdlib_install/bin/` (alongside `ocamlrund`, `ocamlruni`); the symlink farm must pull it from there.
5. Incidental: the interactive shell aliases `cat` to `bat`; use `/bin/cat` or `printf` in heredoc-based scripts on this machine (cost me one bogus probe round before exit codes were checked properly).

## Open questions (from researcher)
- Whether the default extension universe is literally 'stable' or 'stable plus extras': every probe (mode, layouts stable/unboxed records, immutable_arrays, small_numbers, simd types on; comprehensions off) is consistent with 'stable', but no introspection command was found to print the default universe directly.
- Why dune 3.22.2 never invoked ocamldep in --verbose output (0 hits in the full log) — dependency analysis evidently happens another way; harmless here but unexplained.
- Whether the broken bytecode shebang can be fixed at the source (regenerating camlheader or 'ocamlc -use-runtime <path>') rather than worked around with explicit ocamlrun — not tested.
- Bytecode programs needing C stubs (e.g. unix) may additionally need CAML_LD_LIBRARY_PATH; only pure-stdlib bytecode was tested.

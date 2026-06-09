# NEON SIMD from OxCaml on arm64: VERDICT — FEASIBLE (verified compile + run)

Real NEON (128-bit, 16-slot Swiss-table group match: byte broadcast, `cmeq.16b`, movemask-equivalent) works with the compiler at `/Users/krystian/code/ocaml-swiss-table/oxcaml/_build/install/main/bin/ocamlopt.opt`. Two complete programs were written, compiled, disassembled (to confirm real NEON instructions), and run with **100,000 randomized differential tests each vs a scalar reference — all passed**. Files: `/tmp/oxsimd/group_match.ml` (boxed `int8x16`), `/tmp/oxsimd/group_match_u.ml` (unboxed `int8x16#`), `/tmp/oxsimd/neon_stubs.c`.

## Verified compile command

```sh
OCAMLLIB=/Users/krystian/code/ocaml-swiss-table/oxcaml/_build/runtime_stdlib_install/lib/ocaml_runtime_stdlib \
/Users/krystian/code/ocaml-swiss-table/oxcaml/_build/install/main/bin/ocamlopt.opt \
  -extension simd neon_stubs.c group_match_u.ml -o group_match_u
# output: "OK unboxed: 100000 random group matches correct"
```

## Minimal verified .ml (unboxed variant, exact text that compiles and runs)

```ocaml
external bytes_get_int8x16u : bytes -> int -> int8x16#
  = "%caml_bytes_getu128u"   (* note: name is %caml_bytes_getu128u# for unboxed result *)

external int8x16_low_of_int8 : (int[@untagged]) -> (int8x16#[@unboxed])
  = "caml_vec128_unreachable" "caml_int8x16_low_of_int8"
[@@noalloc] [@@builtin]

external int8x16_dup : int8x16# -> int8x16#
  = "caml_vec128_unreachable" "caml_neon_int8x16_dup"
[@@noalloc] [@@unboxed] [@@builtin]

external int8x16_cmpeq : int8x16# -> int8x16# -> int8x16#
  = "caml_vec128_unreachable" "caml_neon_int8x16_cmpeq"
[@@noalloc] [@@unboxed] [@@builtin]

external int64x2_extract :
  (int[@untagged]) -> (int64x2#[@unboxed]) -> (int64[@unboxed])
  = "caml_vec128_unreachable" "caml_neon_int64x2_extract"
[@@noalloc] [@@builtin]

external int64x2_of_int8x16 : int8x16# -> int64x2#
  = "caml_vec128_unreachable" "caml_vec128_cast"  (* free reinterpret *)
[@@noalloc] [@@unboxed] [@@builtin]

let[@inline] mask8_of_word (x : int64) : int =
  let open Int64 in
  let b = logand x 0x0101010101010101L in
  Int64.to_int (shift_right_logical (mul b 0x0102040810204080L) 56) land 0xFF

(* 16-bit movemask: bit i set iff ctrl.(group+i) = h2 *)
let[@inline] group_match (ctrl : bytes) ~group ~h2 : int =
  let g = bytes_get_int8x16u ctrl group in
  let eq = int8x16_cmpeq g (int8x16_dup (int8x16_low_of_int8 h2)) in
  let v = int64x2_of_int8x16 eq in
  mask8_of_word (int64x2_extract 0 v)
  lor (mask8_of_word (int64x2_extract 1 v) lsl 8)
```

(The exact unboxed primitive name in the working file is `"%caml_bytes_getu128u#"` — first `u` = unaligned-width marker in `getu128`, second `u` = unsafe/no-bounds-check, trailing `#` = unboxed result. Boxed variants: `%caml_bytes_getu128` (safe), `%caml_bytes_getu128u` (unsafe), `%caml_string_getu128u` for `string` — all verified.)

**Required C stub file** (`/tmp/oxsimd/neon_stubs.c`): one `void name(void){abort();}` per builtin symbol used (`caml_int8x16_low_of_int8`, `caml_int64x2_low_of_int64`, `caml_neon_int8x16_dup`, `caml_neon_int8x16_cmpeq`, `caml_neon_int8x16_bitwise_and`, `caml_neon_int8x16_hadd`, `caml_neon_int64x2_insert`, `caml_neon_int64x2_extract`, `caml_vec128_cast`, `caml_vec128_unreachable`). Without it, linking fails (`Undefined symbols ... referenced from _camlX__gc_roots`): the compiler inlines every direct call site to the instruction but still emits the external's closure, which references the native symbol. The oxcaml testsuite does exactly the same (`oxcaml/tests/simd/arm64/stub_builtins.c`, `assert(0)` bodies). These stubs are never executed (verified: programs run clean).

## Verified generated assembly (the whole point)

`group_match` compiles to (from `-S`, `/tmp/oxsimd/group_match_u.s`), allocation-free:

```
add  x0, x0, x1, asr #1      ; bytes ptr + untagged index
ldr  q0, [x16]               ; unaligned 16-byte load from Bytes.t
fmov s1, w0                  ; h2 -> lane 0
dup  V1.16B, V1.b[0]         ; broadcast byte
cmeq V0.16B, V0.16B, V1.16B  ; 16-byte equality
umov x0, V0.d[1]             ; extract halves
umov x1, V0.d[0]
...madd/ubfm...              ; (x & 0x0101..01) * 0x0102040810204080 >> 56
```

## Movemask on arm64: what exists and what doesn't

- There is **no** `pmovmskb` equivalent and **no SHRN** (shift-right-narrow) in the arm64 backend op list (`/Users/krystian/code/ocaml-swiss-table/oxcaml/backend/arm64/simd.ml`), so Abseil's `shrn .8b, #4` nibble-mask trick is **not expressible**. `caml_sse2_vec128_movemask_8` exists only in the amd64 backend.
- Two verified emulations producing the standard 16-bit mask:
  1. **Scalar (recommended, no constants needed)**: cast cmeq result to `int64x2#`, `umov` both lanes, compact each half with `(x land 0x0101010101010101) * 0x0102040810204080 >>> 56`. Beware: multiplier `0x8040201008040201` yields a **bit-reversed** mask (empirically confirmed bug, then fixed).
  2. **Vector (`/tmp/oxsimd/group_match.ml`)**: `and` with weights vector `{0x8040201008040201, 0x8040201008040201}` (`caml_neon_int8x16_bitwise_and`), then 3× `caml_neon_int8x16_hadd` (= `addp v.16b`), then `umov x, v.d[0]` `land 0xFFFF`. Verified asm: `and + addp×3 + umov`.
- Useful extra ops for Swiss probing, present in `backend/arm64/simd_selection.ml`: `caml_neon_int8x16_cmpltz` (cmlt #0 → matches empty/deleted, which have the sign bit set, in ONE op, no broadcast needed), `caml_neon_int8x16_cmpgez` (full slots), `caml_neon_int8x16_cmpeqz`, plus min/max/ext/zip. Constant vectors: `caml_int64x2_low_of_int64` + `caml_neon_int64x2_insert 1` — flambda2 folds this into a literal-pool vec128 constant.

## Flags

- `-extension simd` is accepted, and in this build SIMD is actually **enabled by default** (verified: `int8x16` type-checks with no flags; `-no-extension simd` → "Unbound type constructor int8x16"). Boxed types `int8x16`/`int64x2` are compiler predefs (`typing/predef.ml`, stable-maturity SIMD types) — no library dependency needed.
- Unboxed `int8x16#`/`int64x2#` worked with **no additional flags** (layouts also default-on). No `-O3` needed; builtin replacement happens at default optimization.
- The testsuite uses `-extension simd_beta` only for vec256/512-era stuff; not needed for 128-bit.

## Bytecode

**Not supported — fallback required.** Verified: `ocamlc.opt -extension simd group_match.ml` fails at link with `The external function "caml_vec128_unreachable" is not available`. Even the bytecode-linkable primitives abort: `runtime/simd.c:30` is `caml_fatal_error("SIMD is not supported in bytecode mode.")`, and the testsuite's own `bytecode.expected` documents exit 134. A Swiss table must select a scalar implementation for bytecode at build time (e.g., dune virtual module / `select`), or be native-only.

## Performance notes for the implementation task

- Boxed `int8x16` values are heap-boxed when they cross non-inlined function boundaries (observed: weights vector passed as a pointer to the non-inlined boxed version). Use `int8x16#` (verified working) and/or `[@inline]` hot paths; the unboxed `[@inline never]` function compiled with zero allocation.
- The scalar movemask path costs 2 vector ops + 2 `umov` + ~6 ALU ops and needs no live constant; the addp path is 4 vector ops + 1 `umov` but keeps a weights vector live. Benchmark both on Apple Silicon before committing.


## Open questions (from researcher)
- Which movemask emulation is faster on Apple Silicon (scalar multiply-trick vs and+3*addp) — not benchmarked, only verified correct
- Whether dune-driven builds of the actual project need extra stanzas to link the builtin fallback stubs (testsuite uses a foreign_library; plain ocamlopt with a .c file on the command line verified working)
- Exact boxing/allocation behavior of boxed int8x16 across module boundaries under flambda2 — unboxed int8x16# verified allocation-free, boxed variant not fully characterized
- If the Abseil-style shrn-by-4 nibble mask is ever wanted, it requires adding a SHRN op to oxcaml's arm64 backend (not present today)

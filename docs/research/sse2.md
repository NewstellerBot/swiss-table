## Deliverables (all in /Users/krystian/code/ocaml-swiss-table/swiss/lib_sse/)

1. **group_sse.inc** — SSE2 16-wide GROUP module, same shape/contract as lib_neon/group_neon.inc (header docs, [@@builtin] externals with file:line citations, [@inline] lets, unboxed #(int*int) / #(int*int*int) returns). Header carries the required `[UNVERIFIED-ON-HW]` derivation status.
2. **sse_stubs.c** — abort() stubs for every [@@builtin] native symbol (mirrors oxcaml/tests/simd/amd64/stub_builtins.c idiom; deliberately does NOT define caml_no_bytecode_impl). Compiles clean under `clang -Wall -Wextra -c`.
3. **test_group_sse.ml** — standalone differential selftest BODY; the CI build is ONE documented command (in its header):
   `{ echo 'open! Stdlib'; echo 'module G = struct'; cat group_sse.inc; echo 'end'; cat test_group_sse.ml; } > test_group_sse_main.ml && ocamlopt -O3 -extension simd sse_stubs.c test_group_sse_main.ml -o test_group_sse_main && ./test_group_sse_main`
   Checks: exhaustive 65,536 dense-16 helper masks (incl. 0); directed adversarial windows (every uniform byte 0..255, all-FULL/EMPTY/DELETED, tag planted at every one of 16 positions over 5 fills, tags 0x00/0x2A/0x7F, EMPTY/DELETED at every position, alternating + 0x7F/0x80/0x81/0xFE/0xFF boundary patterns, 14 unaligned positions); ≥1.2M randomized windows in 4 regimes (deterministic seed); mask-iteration consistency (lowest_idx/clear_lowest); Gc.minor_words check asserting <0.001 minor words/op; prints `group_sse selftest OK`, exits 0.
4. **Extras (optional, flagged):** `dune` (library swiss_sse, amd64-gated with `enabled_if`, mirrors lib_neon/dune's same-unit pasting rule) and `swiss_sse.mli` (mechanical Swiss_neon→Swiss_sse rename of lib_neon/swiss_neon.mli). swiss/test/dune already contains `(select ... (swiss_sse -> ...))` branches, so these make the amd64 library buildable; delete both if the parent prefers to wire this itself.

## Design (mask format: dense-16, bit i = byte i, masks in [0, 0xFFFF])

- **load**: `%caml_bytes_getu128u#` (arch-generic: lambda/translprim.ml:382-385; amd64 unboxed-result usage oxcaml/tests/simd/arrays_u.ml:141 with int8x16=int8x16# at :14) — same primitive as NEON.
- **movemask**: `caml_sse2_vec128_movemask_8` → pmovmskb_r64_X (backend/amd64/simd_selection.ml:339-340; decl amd64/builtins.ml:621-623). Positional dense masks for ALL components (probe empty is positional — strictly stronger than the contract's nonzero-iff).
- **med**: pmovmskb directly on the raw group (sign bit ⇔ byte ≥ 0x80 ⇔ EMPTY/DELETED). Zero compares.
- **match**: `caml_sse2_int8x16_cmpeq` (pcmpeqb, simd_selection.ml:348; decl builtins.ml:506-508) vs broadcast tag. Broadcast = classic pre-SSSE3 set1_epi8: movd (`caml_int8x16_low_of_int8`, cmm_builtins.ml:369-371, decl ops_int8x16.ml:5-7) → punpcklbw (`caml_sse2_vec128_interleave_low_8`, simd_selection.ml:430-431, decl builtins.ml:661-663) → pshuflw $0 (`caml_sse2_vec128_shuffle_low_16`, simd_selection.ml:425-427 literal-imm required, decl builtins.ml:652-655) → punpcklqdq (`caml_sse2_vec128_interleave_low_64`, simd_selection.ml:439-441, decl builtins.ml:677-679), with free `caml_vec128_cast` reinterprets (cmm_builtins.ml:311-313, decl utils.ml:204-223). Rejected: caml_int8x16_const1 (constant-args-only: cmm_builtins.ml:502-505 + 257-260, errors/i8c1.{ml,expected}); SSSE3 pshufb (not baseline SSE2, arch.ml:100-102); GPR SWAR multiply (tag*0x0101010101010101 overflows 63-bit int for tag ≥ 0x40 ⇒ would need Int64 traffic).
- **empty**: cmpeq vs all-ones, all-ones materialized as `cmpeq8 g g` (self-compare idiom, no constant load, no extra builtin).
- **helpers**: arch-generic ctz/clz builtins (cmm_builtins.ml:900-926 / 865-868) with PROVEN amd64 lowering (backend/amd64/emit.ml:2413-2422 tzcnt/bsf, :2395-2412 lzcnt/bsr — net ctz 0 = 63, clz 0 = 63, clz x = 62−highest_bit, identical to arm64). lowest_idx = ctz m; trailing_zero_count = ctz (m lor 0x10000) (guard bit ⇒ never relies on the zero convention; proofs for m=0/bit0/bit15 in comments); leading_zero_count = clz m − 47 (m=0→16, b=0→15, b=15→0; proof in comments). Unboxed-vector external forms proven by oxcaml/tests/simd/dune:32-38 (builtins_u.ml = unbox_types.ml ++ builtins.ml).

## Local validation performed (arm64; amd64 codegen impossible — unrecognized [@@builtin] names are a hard codegen error, observed)

- The exact CI concatenation typechecks: `ocamlopt -O3 -extension simd -stop-after typing` → OK.
- **Scalar-model run**: built a /tmp harness pasting the .inc's actual op/helper logic (everything below the "Broadcast and the EMPTY detector" banner) over Intel-SDM models of pcmpeqb/punpcklbw/pshuflw/punpcklqdq/pmovmskb/movd (with adversarial junk in movd's unspecified lanes) plus the REAL ctz/clz builtins. Result: helpers 65,536/65,536 OK; 17,150 directed + 1,235,900 randomized windows, 0 failures. This validates the helper formulas on real builtin hardware semantics and the broadcast/empty composition.
- sse_stubs.c compiles (clang). `dune build @all` of the whole project still green on arm64 (swiss_sse skipped by enabled_if); existing NEON-selected smoke test passes.

## Assumptions only CI can verify (also listed in the .inc header)
1. The seven SSE/cast builtin externals compile and lower on x86_64 exactly as cited (declaration forms are copied from working testsuite files, but this toolchain build was never run on amd64).
2. pshuflw's immediate `0` survives flambda2 inlining as a Cconst_int into extract_constant (NEON precedent: srli16's literal 4 does).
3. 0.00 minor words/op under flambda2 -O3 on amd64 (asserted by test phase 4).
4. `-extension simd` is accepted/sufficient on the CI oxcaml (locally the nix oxcaml needs no flag and accepts it; flag kept to match the task's command).
5. Performance variant choices (self-compare all-ones vs const1 constant; pshuflw-chain broadcast) are reasoned, not measured — revisit with the NEON-style benchmark matrix on real hardware.

## Open questions
- CI x86_64 compile+run of lib_sse/test_group_sse.ml (the documented one-liner) — the only remaining proof that the seven SSE builtin externals lower correctly; all names/signatures are cited but were never compiled for amd64.
- Does the pshuflw immediate (literal 0 inside [@inline] dup8) reach simd_selection's extract_constant as a constant under flambda2 -O3 on amd64? (NEON's srli16 4 precedent says yes; a CI failure here would be a loud 'Did not find constant' error.)
- Does the alloc phase report 0.00 minor words/op on amd64 (i.e., does flambda2 keep all vectors/tuples unboxed there as it does for NEON)?
- Should the optional lib_sse/dune + swiss_sse.mli stay? They are amd64-gated (enabled_if) and verified not to affect the arm64 build, and swiss/test/dune already has swiss_sse select branches — but they were not in the explicit 3-file deliverable list.
- Performance variants are unmeasured: empty-detector via cmpeq-self all-ones vs caml_int8x16_const1(-1) constant load, and the 4-op broadcast vs an SSSE3 pshufb path for machines that have it — worth a NEON-style benchmark matrix on real x86_64 hardware later.

(**************************************************************************)
(*                                                                        *)
(*   Group_sse — 16-slot Swiss-table group probing via SSE2 (amd64).     *)
(*                                                                        *)
(*   Implements the GROUP contract (lib/core/core_impl.ml, module type   *)
(*   GROUP) — the amd64 sibling of lib_neon/group_neon.inc. ctrl byte    *)
(*   encoding (docs/research/algorithm.md §1): EMPTY = 0xFF, DELETED =   *)
(*   0x80, FULL = h2 in [0, 0x7F].                                       *)
(*                                                                        *)
(*   DERIVATION STATUS [UNVERIFIED-ON-HW]: authored on an arm64 machine  *)
(*   that CANNOT compile amd64 SIMD code (unrecognized [@@builtin]       *)
(*   names are a hard codegen error: "External annotated with           *)
(*   [@@builtin] is not recognized" — observed locally). Every external  *)
(*   below is therefore derived strictly from the local oxcaml checkout  *)
(*   (backend sources + testsuite), with file:line citations; the file   *)
(*   has been validated locally only up to typing (-stop-after typing)   *)
(*   plus a scalar-model run of the op/helper logic. CI MUST compile     *)
(*   and run lib_sse/test_group_sse.ml on real x86_64 (build command in  *)
(*   that file's header) before this module is trusted.                  *)
(*                                                                        *)
(*   MASK FORMAT (all five mask helpers and every returned mask agree):  *)
(*   "dense-16" — bit i is set for byte offset i (i in 0..15); a mask    *)
(*   occupies bits 0..15 of a native int (value range [0, 0xFFFF]).      *)
(*   Produced directly by pmovmskb (bit i = sign bit of byte i), the     *)
(*   real movemask that NEON lacks — no nibble compression is needed,    *)
(*   so unlike group_neon there is NO sparse encoding and NO exception:  *)
(*   the empty_mask component of probe_find/probe_insert is fully        *)
(*   positional here (the contract only requires nonzero-iff, which      *)
(*   positional trivially satisfies).                                    *)
(*                                                                        *)
(*   CHOSEN VARIANTS (no measurements possible on this machine — these   *)
(*   are reasoned choices; instruction counts below exclude the shared   *)
(*   movdqu load):                                                       *)
(*     med (empty-or-deleted): pmovmskb directly on the raw group —      *)
(*       sign bit set iff byte >= 0x80 iff EMPTY/DELETED. 1 op, zero     *)
(*       compares (the SSE analogue of NEON's winning cmlt-#0 trick).    *)
(*     empty (0xFF): pcmpeqb vs all-ones + pmovmskb, with all-ones       *)
(*       materialized as pcmpeqb g g (x = x on every byte: the classic   *)
(*       self-compare idiom) — no .rodata constant load and no extra     *)
(*       builtin. 3 ops. (caml_int8x16_const1 (-1) would also work but   *)
(*       adds a builtin + likely a rip-relative load; revisit on HW.)    *)
(*     match: pcmpeqb vs broadcast tag + pmovmskb. Broadcast is the      *)
(*       classic pre-SSSE3 _mm_set1_epi8 lowering: movd; punpcklbw;     *)
(*       pshuflw $0; punpcklqdq (4 ops). Alternatives rejected:          *)
(*       - pshufb zero-mask broadcast needs SSSE3                        *)
(*         (caml_ssse3_vec128_shuffle_8, backend/amd64/                  *)
(*         simd_selection.ml:504); this module stays baseline-SSE2 only  *)
(*         (SSE/SSE2 cannot be disabled on x86_64:                       *)
(*         backend/amd64/arch.ml:100-102).                               *)
(*       - caml_int8x16_const1 takes compile-time-constant args only     *)
(*         (backend/cmm_builtins.ml:502-505 via const_int_args:257-260   *)
(*         extracting Cconst_int; non-constant args are a compile error  *)
(*         — oxcaml/tests/simd/errors/i8c1.{ml,expected}), so it cannot  *)
(*         broadcast a runtime tag. Unused.                              *)
(*       - GPR SWAR broadcast (tag * 0x0101010101010101 then movq +      *)
(*         punpcklqdq) overflows the 63-bit native int for tag >= 0x40   *)
(*         (sign-extension corrupts byte 7), so it needs Int64 traffic;  *)
(*         rejected to keep the module free of Int64 values entirely.    *)
(*     probe_find  = load + 4 (broadcast) + 1 cmp + 1 movemask           *)
(*                 + 2 (empty cmp) + 1 movemask        = 9 vector ops.   *)
(*     probe_insert = probe_find + 1 movemask          = 10 ops.         *)
(*     match_empty = 3, match_empty_or_deleted = 1.                      *)
(*                                                                        *)
(*   Mask helpers use the same arch-generic scalar ctz/clz builtins as   *)
(*   group_neon (caml_int_{ctz,clz}_untagged_to_untagged,                *)
(*   backend/cmm_builtins.ml:900-926 / 865-868), which DO have amd64     *)
(*   lowerings: Ictz -> tzcnt, or bsf (backend/amd64/emit.ml:2413-2422;  *)
(*   the cmm wrapper ORs in bit 63 so the input is never zero and both   *)
(*   encodings agree); Iclz -> lzcnt, or bsr^63 with an explicit         *)
(*   64-for-zero branch (emit.ml:2395-2412). Resulting semantics on      *)
(*   amd64 (identical to arm64): ctz 0 = 63, clz 0 = 63, and for         *)
(*   nonnegative x with highest set bit b, clz x = 62 - b. Proofs of     *)
(*   the dense-16 helper formulas are at their definitions below.        *)
(*                                                                        *)
(*   ALLOCATION: all functions are [@inline], take/return only ints     *)
(*   (unboxed tuples for the probes); no vector value escapes a          *)
(*   function and — unlike group_neon — no Int64 value exists at all.    *)
(*   Expected 0.00 minor words/op; ASSERTED by test_group_sse.ml's       *)
(*   Gc.minor_words check in CI (cannot be verified on this machine).    *)
(*                                                                        *)
(*   LINKING: every [@@builtin] external below needs a C stub for its    *)
(*   native symbol (see sse_stubs.c next to this file) — the compiler    *)
(*   inlines all direct call sites but still emits the external's        *)
(*   closure, which references the symbol. The stubs are never called    *)
(*   (abort() bodies). Same idiom as oxcaml/tests/simd/amd64/            *)
(*   stub_builtins.c. caml_no_bytecode_impl is provided by the           *)
(*   runtime. NATIVE-ONLY and AMD64-ONLY: bytecode has no SIMD, and      *)
(*   the builtin names are SSE-specific; select this module per-target   *)
(*   (x86_64 is little-endian, which the byte<->bit numbering of         *)
(*   pmovmskb relies on).                                                *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.flambda_o3]

let width = 16

(* ------------------------------------------------------------------ *)
(* Builtin externals. UNVERIFIED-ON-HW; every declaration is cited to  *)
(* its oxcaml source of truth (paths relative to the oxcaml checkout;  *)
(* the testsuite root is oxcaml/tests/simd/). The unboxed-vector       *)
(* (int8x16# etc.) variants of the testsuite's boxed declarations are  *)
(* exactly what oxcaml/tests/simd/dune:32-38 compiles and runs as      *)
(* builtins_u.ml (= unbox_types.ml ++ builtins.ml).                    *)
(* ------------------------------------------------------------------ *)

(* unaligned, unsafe (no bounds check), unboxed-result 128-bit load.
   Arch-generic lambda primitive (lambda/translprim.ml:382-385,
   Pbytes_load_vec); amd64 testsuite usage with the unboxed result
   type: oxcaml/tests/simd/arrays_u.ml:141 (int8x16 = int8x16# there,
   arrays_u.ml:14). Same primitive as group_neon's load. *)
external get128u : Bytes.t -> int -> int8x16# @@ portable
  = "%caml_bytes_getu128u#"

(* movd r32 -> xmm (low byte = tag, upper bits UNSPECIFIED:
   backend/cmm_builtins.ml:338 "Scalar casts. These leave the top bits
   of the vector unspecified."). Arch-generic Cstatic_cast
   (V128_of_scalar Int8x16), cmm_builtins.ml:369-371; testsuite
   declaration with this exact signature: oxcaml/tests/simd/
   ops_int8x16.ml:5-7; stub: oxcaml/tests/simd/stubs.c:335. *)
external low_of_int8 : (int[@untagged]) -> (int8x16#[@unboxed]) @@ portable
  = "caml_vec128_unreachable" "caml_int8x16_low_of_int8"
  [@@noalloc] [@@builtin]

(* pcmpeqb: backend/amd64/simd_selection.ml:348; testsuite declaration:
   oxcaml/tests/simd/amd64/builtins.ml:506-508; stub:
   oxcaml/tests/simd/amd64/stub_builtins.c:113. *)
external cmpeq8 : int8x16# -> int8x16# -> int8x16# @@ portable
  = "caml_vec128_unreachable" "caml_sse2_int8x16_cmpeq"
  [@@noalloc] [@@unboxed] [@@builtin]

(* punpcklbw: backend/amd64/simd_selection.ml:430-431; testsuite:
   oxcaml/tests/simd/amd64/builtins.ml:661-663; stub:
   amd64/stub_builtins.c:148. *)
external interleave8 : int8x16# -> int8x16# -> int8x16# @@ portable
  = "caml_vec128_unreachable" "caml_sse2_vec128_interleave_low_8"
  [@@noalloc] [@@unboxed] [@@builtin]

(* pshuflw $imm (imm must be a literal at the call site:
   extract_constant ~max:255, backend/amd64/simd_selection.ml:425-427);
   testsuite: oxcaml/tests/simd/amd64/builtins.ml:652-655; stub:
   amd64/stub_builtins.c:146. *)
external shuffle_low16 :
  (int[@untagged]) -> (int16x8#[@unboxed]) -> (int16x8#[@unboxed]) @@ portable
  = "caml_vec128_unreachable" "caml_sse2_vec128_shuffle_low_16"
  [@@noalloc] [@@builtin]

(* punpcklqdq: backend/amd64/simd_selection.ml:439-441; testsuite:
   oxcaml/tests/simd/amd64/builtins.ml:677-679; stub:
   amd64/stub_builtins.c:152. *)
external interleave64 : int64x2# -> int64x2# -> int64x2# @@ portable
  = "caml_vec128_unreachable" "caml_sse2_vec128_interleave_low_64"
  [@@noalloc] [@@unboxed] [@@builtin]

(* pmovmskb r64, xmm — dense 16-bit mask, bit i = sign bit of byte i,
   zero-extended (pmovmskb_r64_X): backend/amd64/
   simd_selection.ml:339-340; testsuite declaration with this exact
   signature: oxcaml/tests/simd/amd64/builtins.ml:621-623; stub:
   amd64/stub_builtins.c:109. *)
external movemask8 : (int8x16#[@unboxed]) -> (int[@untagged]) @@ portable
  = "caml_vec128_unreachable" "caml_sse2_vec128_movemask_8"
  [@@noalloc] [@@builtin]

(* free reinterpret casts (Creinterpret_cast, no code):
   backend/cmm_builtins.ml:311-313; testsuite:
   oxcaml/tests/simd/utils.ml:204-223; stub:
   oxcaml/tests/simd/stubs.c:309. *)
external i16_of_i8 : int8x16# -> int16x8# @@ portable
  = "caml_vec128_unreachable" "caml_vec128_cast"
  [@@noalloc] [@@unboxed] [@@builtin]

external i64_of_i16 : int16x8# -> int64x2# @@ portable
  = "caml_vec128_unreachable" "caml_vec128_cast"
  [@@noalloc] [@@unboxed] [@@builtin]

external i8_of_i64 : int64x2# -> int8x16# @@ portable
  = "caml_vec128_unreachable" "caml_vec128_cast"
  [@@noalloc] [@@unboxed] [@@builtin]

(* hardware ctz/clz, same externals as group_neon. Arch-generic cmm
   construction: ctz = Cctz(x lor (1 lsl 63))
   (backend/cmm_builtins.ml:900-926), clz = Cclz(x land max_int) - 1
   (cmm_builtins.ml:865-868, clear_sign_bit at :104). amd64 lowering:
   backend/amd64/emit.ml:2413-2422 (tzcnt / bsf) and :2395-2412
   (lzcnt / bsr^63, both giving Cclz 0 = 64). Net semantics, both
   arches: ctz 0 = 63; clz 0 = 63; clz x = 62 - (highest set bit) for
   x > 0. Testsuite declarations: oxcaml/tests/simd/scalar_ops.ml:65-67
   and :53-55; stubs: oxcaml/tests/simd/stubs.c:374,377. *)
external ctz : (int[@untagged]) -> (int[@untagged]) @@ portable
  = "caml_no_bytecode_impl" "caml_int_ctz_untagged_to_untagged"
  [@@noalloc] [@@builtin]

external clz : (int[@untagged]) -> (int[@untagged]) @@ portable
  = "caml_no_bytecode_impl" "caml_int_clz_untagged_to_untagged"
  [@@noalloc] [@@builtin]

(* ------------------------------------------------------------------ *)
(* Broadcast and the EMPTY detector                                    *)
(* ------------------------------------------------------------------ *)

(* All 16 bytes := byte 0 of [v] (classic pre-SSSE3 set1_epi8):
     punpcklbw v,v    -> bytes 0,1 = v0          (bytes 2..15 junk)
     pshuflw   $0     -> words 0..3 = word 0     (bytes 0..7 = v0)
     punpcklqdq q,q   -> both qwords = low qword (bytes 0..15 = v0)
   Every step only propagates lanes derived from byte 0, so the
   UNSPECIFIED upper bits left by low_of_int8 are fully eliminated. *)
let[@inline] dup8 v =
  let pair = interleave8 v v in
  let quad = i64_of_i16 (shuffle_low16 0 (i16_of_i8 pair)) in
  i8_of_i64 (interleave64 quad quad)

(* EMPTY (0xFF) detector vector: 0xFF is the only byte equal to
   all-ones; all-ones is materialized as cmpeq8 g g (every byte equals
   itself), the register self-compare idiom — no constant load. *)
let[@inline] empty_vec g = cmpeq8 g (cmpeq8 g g)

(* ------------------------------------------------------------------ *)
(* The GROUP operations                                                *)
(* ------------------------------------------------------------------ *)

(* probe_find ctrl pos tag = #(match_mask, empty_mask).
   match_mask: dense-16, exact byte equality vs [tag] (pcmpeqb has no
   false positives; the contract allows them but never on special
   bytes, which exact equality trivially satisfies for tag < 0x80).
   empty_mask: positional dense-16 mask of EMPTY (0xFF) bytes — the
   contract only requires nonzero-iff, which this satisfies. *)
let[@inline] probe_find (ctrl : Bytes.t) (pos : int) (tag : int) :
    #(int * int) =
  let g = get128u ctrl pos in
  let m = movemask8 (cmpeq8 g (dup8 (low_of_int8 tag))) in
  let e = movemask8 (empty_vec g) in
  #(m, e)

(* probe_insert ctrl pos tag = #(match_mask, empty_mask, med_mask).
   match_mask/empty_mask as in probe_find; med_mask is the positional
   dense-16 mask of EMPTY-or-DELETED bytes: pmovmskb on the RAW group
   (sign bit set iff byte >= 0x80 iff EMPTY/DELETED), zero compares. *)
let[@inline] probe_insert (ctrl : Bytes.t) (pos : int) (tag : int) :
    #(int * int * int) =
  let g = get128u ctrl pos in
  let m = movemask8 (cmpeq8 g (dup8 (low_of_int8 tag))) in
  let e = movemask8 (empty_vec g) in
  let d = movemask8 g in
  #(m, e, d)

(* Positional dense-16 mask of EMPTY bytes (used by the erase rule). *)
let[@inline] match_empty (ctrl : Bytes.t) (pos : int) : int =
  movemask8 (empty_vec (get128u ctrl pos))

(* Positional dense-16 mask of EMPTY-or-DELETED bytes. *)
let[@inline] match_empty_or_deleted (ctrl : Bytes.t) (pos : int) : int =
  movemask8 (get128u ctrl pos)

(* ------------------------------------------------------------------ *)
(* Mask helpers (dense-16 format; masks are ints in [0, 0xFFFF])       *)
(* ------------------------------------------------------------------ *)

(* Byte offset (0..15) of the lowest set position; m <> 0 required.
   For m in [1, 0xFFFF], ctz m IS the byte offset (bit i = byte i). *)
let[@inline] lowest_idx (m : int) : int = ctz m

let[@inline] clear_lowest (m : int) : int = m land (m - 1)

(* Count of consecutive unset byte positions from offset 0; 16 for 0.
   Guard bit 16 makes the formula total WITHOUT relying on the
   ctz 0 = 63 convention (the input is never zero):
     m <> 0: the lowest set bit i of m satisfies i <= 15 < 16, so the
             guard is above it and ctz (m lor 0x10000) = i.
             Edges: m = 1 (bit 0)  -> 0;  m = 0x8000 (bit 15) -> 15.
     m =  0: ctz 0x10000 = 16. *)
let[@inline] trailing_zero_count (m : int) : int = ctz (m lor 0x10000)

(* Count of consecutive unset byte positions from offset 15 down; 16
   for 0. With clz as cited above (clz x = 62 - b for highest set bit
   b; clz 0 = 63):
     m <> 0, highest set bit b in [0, 15]:
       clz m - 47 = (62 - b) - 47 = 15 - b
       = number of unset positions in 15 down to b+1.
       Edges: b = 15 -> 0;  b = 0 (m = 1) -> 15.
     m =  0: 63 - 47 = 16. *)
let[@inline] leading_zero_count (m : int) : int = clz m - 47

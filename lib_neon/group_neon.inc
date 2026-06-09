(**************************************************************************)
(*                                                                        *)
(*   Group_neon — 16-slot Swiss-table group probing via NEON (arm64).    *)
(*                                                                        *)
(*   Implements the GROUP contract (16-wide sibling of lib/swiss.ml's    *)
(*   8-wide SWAR Group). ctrl byte encoding (docs/research/algorithm.md  *)
(*   §1): EMPTY = 0xFF, DELETED = 0x80, FULL = h2 in [0, 0x7F].          *)
(*                                                                        *)
(*   MASK FORMAT (all five mask helpers and every returned mask agree):  *)
(*   "sparse-4" — bit (4*i) is set for byte offset i (i in 0..15); a     *)
(*   mask occupies bits 0,4,...,60 of a native int. Produced by the      *)
(*   nibble movemask: cmeq/cmlt -> ushr.8h #4 -> xtn.8b -> umov.d[0]     *)
(*   -> and 0x1111111111111111 (the and is a single arm64 logical-       *)
(*   immediate orr/and; emulating Abseil's shrn-#4 trick, which needs    *)
(*   no SHRN op: ushr+xtn express it with ops this backend has).         *)
(*   EXCEPTION: the empty_mask component of probe_find/probe_insert is   *)
(*   only guaranteed nonzero-iff-some-byte-is-EMPTY (callers only test   *)
(*   <> 0); it is NOT positional. Use match_empty for positional needs.  *)
(*                                                                        *)
(*   CHOSEN VARIANTS + MEASURED NUMBERS (Apple Silicon, OxCaml           *)
(*   5.2.0+ox flambda2 -O3; 200M-iteration hot loop over a 64KB ctrl     *)
(*   buffer, unaligned LCG positions; raw ns/op including a 1.02 ns      *)
(*   loop+LCG baseline; run-to-run spread < 0.01 ns):                    *)
(*                                                                        *)
(*     probe_find variants:                                              *)
(*       nibble match + vector empty (mvn+cmeqz+addp.2d)   1.13  CHOSEN  *)
(*       nibble match + cmeq-vs-ones-const empty           1.14          *)
(*       nibble match + scalar SWAR empty (2x ldr x)       1.49          *)
(*       weighted single-extraction (match+empty, 1 umov)  1.51          *)
(*       dense16 and-weights + 3x addp + vector empty      1.21          *)
(*       dense16 and-weights + 3x addp + scalar empty      1.60          *)
(*       dense16 scalar multiply-trick per 64-bit half     2.41          *)
(*       pure 2x64-bit SWAR (no NEON)                      2.99          *)
(*       SWAR-8 (lib/swiss.ml Group, 8 bytes/op)           1.44          *)
(*       => per byte scanned: 0.0069 ns (chosen, 16B) vs 0.052 ns       *)
(*          (SWAR-8): ~7.5x cheaper per byte at the group-op level.     *)
(*     probe_insert variants:                                            *)
(*       nibble m + cmlt-nibble med + vector empty         1.28  CHOSEN  *)
(*       same but cmeq-vs-ones empty                       1.30          *)
(*       dense16 addp m/med + vector empty                 1.39          *)
(*       nibble m/med + scalar SWAR empty                  1.61          *)
(*       weighted single-extraction (1 umov, 3 consts)     1.90          *)
(*       dense16 multiply-trick / pure SWAR             3.37/3.99        *)
(*     empty-or-deleted: cmlt #0 (sign bit, no broadcast)  1.025         *)
(*       vs cmeq-vs-0xFF + cmeq-vs-0x80 + orr              1.034         *)
(*       vs scalar SWAR + compress                         1.75          *)
(*     mask helpers (per call, incl. load+loop):                         *)
(*       hardware ctz/clz (rbit+clz via builtins)  0.46-0.65  CHOSEN     *)
(*       de Bruijn multiply                        0.66                  *)
(*       256-byte lookup table                     0.61                  *)
(*     probe_find + full mask iteration: sparse-4 2.28 vs best           *)
(*     dense-16 2.55 — sparse-4 wins end-to-end despite its helpers      *)
(*     costing ~0.2 ns more than dense-16's ctz16/clz16.                 *)
(*                                                                        *)
(*   Scalar ctz/clz builtins (caml_int_{ctz,clz}_untagged_to_untagged)   *)
(*   compile to rbit+clz / clz — discovered in backend/cmm_builtins.ml;  *)
(*   not covered by docs/research/simd.md.                               *)
(*                                                                        *)
(*   ALLOCATION: all functions are [@inline], take/return only ints     *)
(*   (unboxed tuples for the probes); no vector or int64 value escapes   *)
(*   a function. Verified 0.00 minor words/op over 1M-call probe loops   *)
(*   and by -S inspection (loops inline to ldr q/dup/cmeq/...; no        *)
(*   caml_call_gc, no closure allocation).                               *)
(*                                                                        *)
(*   LINKING: every [@@builtin] external below needs a C stub for its    *)
(*   native symbol (see neon_stubs.c next to this file) — the compiler   *)
(*   inlines all direct call sites but still emits the external's        *)
(*   closure, which references the symbol. The stubs are never called    *)
(*   (abort() bodies). caml_no_bytecode_impl is provided by the          *)
(*   runtime. NATIVE-ONLY and ARM64-ONLY: bytecode has no SIMD, and      *)
(*   the builtin names are NEON-specific; select this module per-target  *)
(*   (arm64 is always little-endian for OCaml, which the byte<->lane     *)
(*   numbering below relies on).                                         *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.flambda_o3]

let width = 16

(* ------------------------------------------------------------------ *)
(* Builtin externals (verified against this toolchain; see             *)
(* docs/research/simd.md and backend/arm64/simd_selection.ml)          *)
(* ------------------------------------------------------------------ *)

(* unaligned, unsafe (no bounds check), unboxed-result 128-bit load *)
external get128u : Bytes.t -> int -> int8x16# @@ portable
  = "%caml_bytes_getu128u#"

external low_of_int8 : (int[@untagged]) -> (int8x16#[@unboxed]) @@ portable
  = "caml_vec128_unreachable" "caml_int8x16_low_of_int8"
  [@@noalloc] [@@builtin]

(* dup.16b lane 0 *)
external dup8 : int8x16# -> int8x16# @@ portable
  = "caml_vec128_unreachable" "caml_neon_int8x16_dup"
  [@@noalloc] [@@unboxed] [@@builtin]

(* cmeq.16b *)
external cmpeq8 : int8x16# -> int8x16# -> int8x16# @@ portable
  = "caml_vec128_unreachable" "caml_neon_int8x16_cmpeq"
  [@@noalloc] [@@unboxed] [@@builtin]

(* cmeq.16b vs #0 *)
external cmpeqz8 : int8x16# -> int8x16# @@ portable
  = "caml_vec128_unreachable" "caml_neon_int8x16_cmpeqz"
  [@@noalloc] [@@unboxed] [@@builtin]

(* cmlt.16b vs #0 — sign-bit test: EMPTY/DELETED in one op, no broadcast *)
external cmpltz8 : int8x16# -> int8x16# @@ portable
  = "caml_vec128_unreachable" "caml_neon_int8x16_cmpltz"
  [@@noalloc] [@@unboxed] [@@builtin]

(* mvn.16b *)
external not8 : int8x16# -> int8x16# @@ portable
  = "caml_vec128_unreachable" "caml_neon_int8x16_bitwise_not"
  [@@noalloc] [@@unboxed] [@@builtin]

(* ushr.8h #imm (immediate must be a literal at the call site) *)
external srli16 :
  (int[@untagged]) -> (int16x8#[@unboxed]) -> (int16x8#[@unboxed]) @@ portable
  = "caml_vec128_unreachable" "caml_neon_int16x8_srli"
  [@@noalloc] [@@builtin]

(* xtn.8b (low-half narrow) *)
external xtn16 : int16x8# -> int8x16# @@ portable
  = "caml_vec128_unreachable" "caml_neon_cvt_int16x8_to_int8x16_low"
  [@@noalloc] [@@unboxed] [@@builtin]

(* addp.2d *)
external hadd64 : int64x2# -> int64x2# -> int64x2# @@ portable
  = "caml_vec128_unreachable" "caml_neon_int64x2_hadd"
  [@@noalloc] [@@unboxed] [@@builtin]

(* umov x, v.d[lane] *)
external extract64 :
  (int[@untagged]) -> (int64x2#[@unboxed]) -> (int64[@unboxed]) @@ portable
  = "caml_vec128_unreachable" "caml_neon_int64x2_extract"
  [@@noalloc] [@@builtin]

(* free reinterpret casts *)
external i16_of_i8 : int8x16# -> int16x8# @@ portable
  = "caml_vec128_unreachable" "caml_vec128_cast"
  [@@noalloc] [@@unboxed] [@@builtin]

external i64_of_i8 : int8x16# -> int64x2# @@ portable
  = "caml_vec128_unreachable" "caml_vec128_cast"
  [@@noalloc] [@@unboxed] [@@builtin]

(* hardware ctz/clz: rbit+clz / clz, with a guard bit so x = 0 gives 63
   (the OR'd guard is bit 63 for ctz; clz subtracts 1 after clearing the
   shifted-in sign bit, so clz 0 = 63 too) *)
external ctz : (int[@untagged]) -> (int[@untagged]) @@ portable
  = "caml_no_bytecode_impl" "caml_int_ctz_untagged_to_untagged"
  [@@noalloc] [@@builtin]

external clz : (int[@untagged]) -> (int[@untagged]) @@ portable
  = "caml_no_bytecode_impl" "caml_int_clz_untagged_to_untagged"
  [@@noalloc] [@@builtin]

(* ------------------------------------------------------------------ *)
(* Movemask and the empty-bool reduction                               *)
(* ------------------------------------------------------------------ *)

(* [v] must have 0x00/0xFF bytes (a comparison result). Returns the
   64-bit nibble word: nibble i = 0xF iff byte i of [v] is 0xFF.
   ushr.8h #4 + xtn.8b is the 2-op emulation of shrn.8b #4. *)
let[@inline] nibword (v : int8x16#) : int64 =
  extract64 0 (i64_of_i8 (xtn16 (srli16 4 (i16_of_i8 v))))

(* sparse-4 mask of a 0x00/0xFF-byte vector. The to_int truncation to
   63 bits is safe: the highest used bit is 4*15 = 60. *)
let[@inline] sparse4 (v : int8x16#) : int =
  Int64.to_int (Int64.logand (nibword v) 0x1111111111111111L)

(* Nonzero iff some byte of [v] is nonzero, for 0x00/0xFF-byte vectors:
   addp.2d folds the two 64-bit halves; h0 + h1 = 0 (mod 2^64) forces
   h0 = h1 = 0 because the low nonzero byte of -h1 would be 0x01, which
   a 00/FF-byte word cannot have. The >>> 7 keeps the result's nonzero
   bytes (all >= 0xFE) visible inside a 63-bit int. *)
let[@inline] anybyte (v : int8x16#) : int =
  let x = i64_of_i8 v in
  Int64.to_int (Int64.shift_right_logical (extract64 0 (hadd64 x x)) 7)

(* EMPTY (0xFF) detector vector: the only byte whose complement is 0. *)
let[@inline] empty_vec (g : int8x16#) : int8x16# = cmpeqz8 (not8 g)

(* ------------------------------------------------------------------ *)
(* The GROUP operations                                                *)
(* ------------------------------------------------------------------ *)

(* probe_find ctrl pos tag = #(match_mask, empty_mask).
   match_mask: sparse-4, exact byte equality vs [tag] (cmeq has no
   false positives; the contract allows them but never on special
   bytes, which exact equality trivially satisfies for tag < 0x80).
   empty_mask: boolean only — nonzero iff some byte = EMPTY (0xFF). *)
let[@inline] probe_find (ctrl : Bytes.t) (pos : int) (tag : int) :
    #(int * int) =
  let g = get128u ctrl pos in
  let m = sparse4 (cmpeq8 g (dup8 (low_of_int8 tag))) in
  let e = anybyte (empty_vec g) in
  #(m, e)

(* probe_insert ctrl pos tag = #(match_mask, empty_mask, med_mask).
   match_mask/empty_mask as in probe_find; med_mask is the positional
   sparse-4 mask of EMPTY-or-DELETED bytes (top bit set => cmlt #0). *)
let[@inline] probe_insert (ctrl : Bytes.t) (pos : int) (tag : int) :
    #(int * int * int) =
  let g = get128u ctrl pos in
  let m = sparse4 (cmpeq8 g (dup8 (low_of_int8 tag))) in
  let d = sparse4 (cmpltz8 g) in
  let e = anybyte (empty_vec g) in
  #(m, e, d)

(* Positional sparse-4 mask of EMPTY bytes (used by the erase rule). *)
let[@inline] match_empty (ctrl : Bytes.t) (pos : int) : int =
  sparse4 (empty_vec (get128u ctrl pos))

(* Positional sparse-4 mask of EMPTY-or-DELETED bytes. *)
let[@inline] match_empty_or_deleted (ctrl : Bytes.t) (pos : int) : int =
  sparse4 (cmpltz8 (get128u ctrl pos))

(* ------------------------------------------------------------------ *)
(* Mask helpers (sparse-4 format; masks are nonneg ints, bits 0..60)   *)
(* ------------------------------------------------------------------ *)

(* Byte offset (0..15) of the lowest set position; m <> 0 required. *)
let[@inline] lowest_idx (m : int) : int = ctz m lsr 2

let[@inline] clear_lowest (m : int) : int = m land (m - 1)

(* Count of consecutive unset byte positions from offset 0; 16 for 0.
   ctz m = 4*i for the lowest set byte i, and 63 for m = 0:
   (4*i + 3) lsr 2 = i;  (63 + 3) lsr 2 = 16. *)
let[@inline] trailing_zero_count (m : int) : int = (ctz m + 3) lsr 2

(* Count of consecutive unset byte positions from offset 15 down; 16
   for 0. clz m = 62 - 4*i for the highest set byte i (63-bit clz of a
   nonnegative int), and 63 for m = 0:
   16 - ((66 - (62 - 4*i)) lsr 2) = 16 - (i + 1) = 15 - i;
   16 - ((66 - 63) lsr 2)         = 16 - 0      = 16. *)
let[@inline] leading_zero_count (m : int) : int = 16 - ((66 - clz m) lsr 2)

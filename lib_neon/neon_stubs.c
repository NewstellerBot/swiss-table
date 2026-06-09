/* Fallback symbols for group_neon.ml's [@@builtin] externals.
 *
 * Never called from native code: the compiler replaces every direct call
 * site with the corresponding NEON / bit-manipulation instruction(s). The
 * symbols exist only because each external's closure (emitted into the
 * unit's gc_roots) references its native symbol; without them linking
 * fails with "Undefined symbols ... referenced from _camlGroup_neon__
 * gc_roots". Same idiom as oxcaml/tests/simd/arm64/stub_builtins.c.
 * abort() bodies so any accidental call is loud.
 *
 * caml_no_bytecode_impl (the bytecode-name placeholder of the scalar
 * ctz/clz builtins) is already provided by the OCaml runtime (misc.c) —
 * do NOT define it here or linking fails with a duplicate symbol.
 */
#include <stdlib.h>

#define BUILTIN(name) void name(void) { abort(); }

BUILTIN(caml_int8x16_low_of_int8)
BUILTIN(caml_neon_int8x16_dup)
BUILTIN(caml_neon_int8x16_cmpeq)
BUILTIN(caml_neon_int8x16_cmpeqz)
BUILTIN(caml_neon_int8x16_cmpltz)
BUILTIN(caml_neon_int8x16_bitwise_not)
BUILTIN(caml_neon_int16x8_srli)
BUILTIN(caml_neon_cvt_int16x8_to_int8x16_low)
BUILTIN(caml_neon_int64x2_hadd)
BUILTIN(caml_neon_int64x2_extract)
BUILTIN(caml_vec128_cast)
BUILTIN(caml_vec128_unreachable)
BUILTIN(caml_int_ctz_untagged_to_untagged)
BUILTIN(caml_int_clz_untagged_to_untagged)

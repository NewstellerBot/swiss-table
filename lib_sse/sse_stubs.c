/* Fallback symbols for group_sse.inc's [@@builtin] externals.
 *
 * Never called from native code: the compiler replaces every direct call
 * site with the corresponding SSE2 / bit-manipulation instruction(s). The
 * symbols exist only because each external's closure (emitted into the
 * unit's gc_roots) references its native symbol; without them linking
 * fails with "Undefined symbols ... referenced from ..._gc_roots".
 * Same idiom as oxcaml/tests/simd/amd64/stub_builtins.c (and the shared
 * oxcaml/tests/simd/stubs.c, which stubs caml_vec128_unreachable at :308,
 * caml_vec128_cast at :309, caml_int8x16_low_of_int8 at :335 and the
 * scalar ctz/clz at :374/:377). abort() bodies so any accidental call is
 * loud.
 *
 * caml_no_bytecode_impl (the bytecode-name placeholder of the scalar
 * ctz/clz builtins) is already provided by the OCaml runtime (misc.c) —
 * do NOT define it here or linking fails with a duplicate symbol.
 */
#include <stdlib.h>

#define BUILTIN(name) void name(void) { abort(); }

BUILTIN(caml_int8x16_low_of_int8)
BUILTIN(caml_sse2_int8x16_cmpeq)
BUILTIN(caml_sse2_vec128_interleave_low_8)
BUILTIN(caml_sse2_vec128_shuffle_low_16)
BUILTIN(caml_sse2_vec128_interleave_low_64)
BUILTIN(caml_sse2_vec128_movemask_8)
BUILTIN(caml_vec128_cast)
BUILTIN(caml_vec128_unreachable)
BUILTIN(caml_int_ctz_untagged_to_untagged)
BUILTIN(caml_int_clz_untagged_to_untagged)

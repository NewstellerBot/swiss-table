# Swiss

A Swiss table (hashbrown-style flat hash table with SWAR group probing) for
[OxCaml](https://oxcaml.org), exposing **exactly** the OCaml stdlib `Hashtbl`
API — including the parts people forget exist: multi-binding semantics
(`add` shadows, `find_all`, `remove` un-shadows), `randomize`/seeding,
`Make`/`MakeSeeded`/`MakePortable`/`MakeSeededPortable`, `stats`, `rebuild`,
and the seq functions. `module Swiss : (module type of Hashtbl)` modulo the
documented deviations below.

## Design

- **Flat core** (`lib/swiss.ml`): hashbrown control-byte encoding
  (`EMPTY=0xFF`, `DELETED=0x80`, `FULL=h2`), 8-slot groups probed with
  64-bit SWAR bit tricks, triangular probing over groups, 7/8 max load,
  tombstones with the hashbrown EMPTY-vs-DELETED erase rule, same-size
  tombstone-purge rehash. Constants and formulas follow the real hashbrown
  sources — see `docs/research/algorithm.md` for the derivation with
  permalinks.
- **Multi-binding via shadow stacks**: the flat table holds each key's
  *current* binding; older (shadowed) bindings live in a lazily-created side
  table of per-key stacks. Hot paths are identical to a single-binding Swiss
  table; tables that never use duplicate `add` never pay anything.
- **OxCaml specifics**: the interface carries stdlib's `@@ portable` modality
  and the `mutable_data with 'a with 'b` kind; slots are `Obj.t` arrays under
  `[@@unsafe_allow_any_mode_crossing]` (the stdlib `domain.ml` idiom).
  Reentrant user callbacks (`equal`/`hash`/iteration functions that mutate the
  table mid-operation) are memory-safe via a core-snapshot discipline
  (`docs/design.md` §2).

The full design (and the adversarial review that shaped it) is in
`docs/design.md` and `docs/design-review.md`.

## Behavioral deviations from stdlib (documented, deliberate)

- Iteration order: only the documented guarantees hold (unspecified order,
  deterministic for non-randomized tables, per-key most-recent-first) — not
  stdlib's exact order.
- `add` evaluates key equality (stdlib's `add` never does): keys whose
  polymorphic `compare` diverges (distinct equal cyclic values) or raises
  (closures) are not supported by `add`.
- Functor `equal` must be an equivalence relation consistent with `hash`;
  asymmetric/non-equivalence `equal` is unspecified.
- `stats`: `num_buckets`/histogram describe slots and bindings-per-key, not
  stdlib's chain lengths.
- No marshal-format compatibility with stdlib tables (Swiss↔Swiss marshaling
  works; `rebuild` validates and rejects foreign representations).

## Build

Requires the OxCaml toolchain (this checkout uses the nix-built compiler in
`../oxcaml/result/bin`):

```sh
source ./env.sh
$DUNE build          # library
$DUNE runtest        # smoke + unit/regression + differential fuzzer (~20 s)
$DUNE exec bench/bench.exe -- 1000 100000 1000000
```

## Testing

- `test/test_diff.ml`: differential fuzzer — 400 sequences × 2000 ops per key
  universe (small-int, string with physically-distinct equal keys, float with
  nan/-0.0, `Make`, `MakeSeeded`), every operation checked for observational
  equivalence against `Stdlib.Hashtbl` after each step (~4M ops).
- `test/test_unit.ml`: 13 groups of targeted regressions (resize boundaries,
  tombstone churn, multi-binding ladders, key-object identity, reentrancy
  memory-safety, randomization, rebuild) plus an `Obj`-level representation
  invariant checker.

## Benchmarks (Apple Silicon, arm64, OxCaml 5.2.0+ox flambda2)

ns/op, min of 5 runs, `~random:false`, vs the stdlib `Hashtbl` shipped with
the same compiler. All hot paths are allocation-free (verified with
`bench/allocprobe.ml`: 0.00 minor words/op for find/mem/replace, matching
stdlib):

```
N = 1,000,000            Swiss   Hashtbl
int    find hit           26.2      25.9     parity  (Make functor: 21.4 vs 29.4, 1.4x)
int    find miss           7.7      33.4     4.3x
int    mem 50/50          13.6      32.1     2.4x
int    replace existing   28.9      28.5     parity  (Make: 26.6 vs 40.8, 1.5x)
int    insert (grow)      63.1      63.7     parity
int    churn rm/add       32.9      26.8     0.8x
int    iter                7.2       9.9     1.4x
string find hit           28.7      42.2     1.5x
string find miss          14.9      60.8     4.1x
string mem 50/50          29.0      53.2     1.8x
string insert (grow)      83.8      84.8     parity
```

The signature Swiss-table wins are misses and membership tests (the h2 byte
filter and EMPTY-group early exit mean a string miss usually performs zero
string comparisons). Two write paths remain slower at small N: `insert` into
tiny tables (~43 vs 21 ns at N=1k — `Hashtbl.add` is a blind list prepend,
while multi-binding semantics force this table to probe for an existing
binding on every `add`) and remove/re-add churn (tombstone bookkeeping).
Both are structural, not implementation artifacts.

## Swiss_neon: the NEON 16-wide variant (arm64, native-only)

`swiss_neon` is a second instantiation of the same engine with 16-slot groups
probed by real NEON (`cmeq.16b`; movemask via the `ushr.8h #4 + xtn.8b`
nibble trick — Abseil's `shrn` emulated with ops this backend has; hardware
`rbit+clz` for mask iteration). Same exact `Hashtbl` API, same fuzzer-verified
semantics, allocation-free. Native-only (bytecode has no SIMD; the
`[@@builtin]` externals link against abort-stub C symbols).

Both libraries are generated from one engine template
(`lib/core/engine_template.inc`) pasted with their group implementation into
a single compilation unit per instantiation — a deliberate move past two
flambda2 limitations found along the way: functor applications of this size
are not inlined, and cross-unit calls returning unboxed tuples go through
`caml_apply` uninlined.

Fair per-family runs (each implementation in its own process, ns/op):

```
                       N = 1,000           N = 100,000          N = 1,000,000
                   Neon  SWAR  Htbl     Neon  SWAR  Htbl     Neon  SWAR  Htbl
int  find hit      10.0  12.9  13.8     13.2  18.9  14.9     36.9  32.9  30.2
int  find miss      6.9   6.0  11.9     11.5  13.9  17.8      8.4   8.0  39.9
int  mem 50/50      7.9  10.0  12.9     11.8  16.4  16.6     14.7  15.0  38.5
int  replace       12.9  16.0  15.0     14.7  21.0  16.9     37.7  34.3  34.2
int  insert(grow)  47.9  49.8  21.0     38.4  47.0  32.8     65.6  68.4  75.0
int  churn         15.0  20.0  11.0     25.8  29.9  13.7     38.6  38.4  33.4
str  find hit      11.9  16.9  18.1     14.8  20.8  21.8     37.9  34.4  50.2
str  find miss      8.8   7.9  17.9     14.0  16.4  23.7     12.6  10.2  75.0
```

Reading: while the table fits in cache (≤ ~100k entries), NEON is 25–45%
faster than SWAR across the board and beats stdlib on everything except
churn and tiny-table insert. At 1M entries every implementation is
DRAM-latency-bound and NEON ≈ SWAR (the 16-byte ctrl windows even straddle
cache lines slightly more often than 8-byte ones). Pick `swiss_neon` for
native arm64 workloads with cache-resident tables; `swiss` is the portable
default (any arch, bytecode included).

## CI grid

`.github/workflows/ci.yml` builds, tests, and benchmarks on every platform
OxCaml supports: Linux x86_64 (`ubuntu-24.04`), Linux arm64
(`ubuntu-24.04-arm`, free for public repos), macOS arm64 (`macos-15`), and
macOS x86_64 (`macos-15-intel`, experimental — upstream says "x86 macOS may
still work" and doesn't CI it). Windows is unsupported by OxCaml.

Each job: provisions OxCaml 5.2.0+ox via `ocaml/setup-ocaml@v3` from the ox
opam repository (~35–90 min cold compiler bootstrap, then cached; warm runs
restore in minutes), builds, runs the **SSE2 hardware selftest** on x86_64
(the SSE group module was derived from the amd64 backend sources on an arm64
machine — `lib_sse/test_group_sse.ml` is its first execution on real
silicon), runs the differential fuzzers for both the SWAR and per-arch SIMD
instantiations, asserts the allocation-free property, and benchmarks each
implementation family in its own process. A final job aggregates all
platforms into a single markdown grid (SIMD / SWAR / stdlib per cell) in the
run summary via `scripts/aggregate_bench.py`. Architecture selection is
build-system-level: `swiss_neon` is `enabled_if arm64`, `swiss_sse`
`enabled_if amd64`, and tests/benches pick whichever exists through dune
`(select)` with a no-op fallback.

CI numbers come from shared runners — treat them as indicative; the
methodology (min-of-5, per-family processes) limits but does not eliminate
noise.

## Possible future work

- Interleaved key/value array to halve the generic-array tag checks and put
  key+value on one cache line (the main lever left for the 1M-entry hit path).

(The true in-place tombstone purge from `docs/research/algorithm.md` §8 is
implemented for the generic interface — zero-allocation purges; functor
tables keep the copying purge so a raising/reentrant user hash can never
observe or corrupt a half-rehashed table.)

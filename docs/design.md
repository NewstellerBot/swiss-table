# Swiss — design document (rev 2, post-adversarial-review)

A Swiss table (hashbrown-style flat hash table) for OxCaml whose public interface and
observable behavior match the OxCaml 5.2.0+ox stdlib `Hashtbl` **exactly** (for
law-abiding keys; see §1 deviations).

Inputs: `docs/research/api.md` (behavioral contract, **API §n**),
`docs/research/algorithm.md` (**ALG §n**), `docs/research/simd.md`,
`docs/research/toolchain.md`, `docs/design-review.md` (adversarial findings, **REV**;
all serious/minor findings are incorporated below).

## 1. Goals / non-goals / documented deviations

Goals:
- Public module `Swiss` with the exact signature of `Hashtbl` (mli mirrored verbatim,
  incl. `@@ portable`, the `unsynchronized_access` alert block, the kind annotation,
  `Make`/`MakeSeeded`/`MakePortable`/`MakeSeededPortable`, `@since` docs;
  `{!Hashtbl.x}` xrefs become `{!Swiss.x}`).
- All documented stdlib semantics (API §2): multi-binding recency contract,
  `compare … = 0` generic equality with stdlib's argument orders, `replace`
  in-place with key-object overwrite, randomization machinery, `of_seq` uses
  `replace` / `add_seq` uses `add`, `Not_found` from `find` only, O(1) `length`.
- Flat core per ALG: hashbrown ctrl encoding, 8-slot SWAR groups, triangular
  probing, 7/8 load, tombstone rules. NEON 16-slot group as a later drop-in.

Non-goals / **documented deviations** (each verified against stdlib by REV):
- No bit-exact iteration order parity with stdlib (only the documented
  guarantees: unspecified order, deterministic across runs when non-randomized,
  per-key most-recent-first).
- No marshal-format compatibility with stdlib's representation. Swiss↔Swiss
  marshaling round-trips (REV verified). Unmarshaling bytes produced from a
  *stdlib* table at type `Swiss.t` is UB as it is for any wrong type; `rebuild`
  (the documented migration entry point) fail-closed-checks the representation
  shape and raises `Invalid_argument "Swiss: unsupported hash table format"`.
- **`add` evaluates key equality** (stdlib's `add` is a blind prepend that never
  calls `compare`/`equal`). Consequence: keys on which `compare` diverges
  (structurally-equal distinct cyclic values) or raises (closures inside
  compare-equal keys) are not supported by `add`, unlike stdlib (REV semantics#2,
  demonstrated). Inherent to open addressing; excluded from the fuzzer oracle.
- Observable parity is guaranteed only when `equal` is an **equivalence relation
  consistent with `hash`** (the `HashedType` contract's only sane reading).
  Non-equivalence/asymmetric `equal` is unspecified-divergent (REV semantics#5,
  algorithm#5: stdlib's behavior under such `equal` depends on bucket
  interleaving and is unmatchable by any keyed structure). Within each
  operation, stdlib's equality *argument orders* are still replicated (§5).
  `find_all` does not re-test `equal` on shadow-stack entries (stdlib re-tests
  per cons cell — indistinguishable for equivalence `equal`).
- `filter_map_inplace` and `stats`-via-`rebuild`… (none); but note: `filter_map_inplace`
  on a table that currently holds duplicates calls the hash function (shadow
  lookups), which stdlib traversals never do. `iter`/`fold`/`to_seq`/`stats` do
  NOT hash (two-phase traversal, §3). Side-effecting/raising hash functions are
  excluded from the fuzzer oracle for `filter_map_inplace` only.
- Independent PRNG stream (same construction as stdlib, necessarily different
  DLS key; stdlib's stream is unobservable anyway).

## 2. Core representation

```ocaml
type ('a, 'b) core = {
  ctrl : Bytes.t;          (* length buckets + 8 *)
  keys : Obj.t array;      (* length buckets; dummy = Obj.repr () *)
  vals : Obj.t array;      (* length buckets; dummy = Obj.repr () *)
  mask : int;              (* buckets - 1 *)
}

type ('a, 'b) t : mutable_data with 'a with 'b = {
  mutable core : ('a, 'b) core;     (* swapped WHOLESALE on resize/reset *)
  mutable items : int;              (* FULL slots = distinct live keys *)
  mutable growth_left : int;        (* inserts into EMPTY still allowed *)
  mutable shadow : ('a, 'b) shadow; (* older bindings of duplicated keys *)
  mutable nshadow : int;            (* total shadowed bindings *)
  seed : int;
  mutable initial_buckets : int;    (* clamped size from create; reset target *)
} [@@unsafe_allow_any_mode_crossing
   (* Obj.t slots only ever hold 'a keys, 'b values, ('a * 'b) list stacks,
      or the immediate () dummy — so the representation genuinely supports
      mutable_data with 'a with 'b. Same idiom as stdlib domain.ml. *)]

and ('a, 'b) shadow = ('a, ('a * 'b) list) t option
```

- **Kind/mode mechanics (REV all-three-lenses, compiler-verified):** the kind
  ascription must be on the `.ml` declaration with
  `[@@unsafe_allow_any_mode_crossing]`; without it the Obj.t-array record's
  inferred kind is rejected against the mli's
  `type (!'a, !'b) t : mutable_data with 'a with 'b`. (Typed `'a array` fields
  would pass the kind check but are rejected for the flambda2 +
  `flat_float_array: true` specialization hazard — REV verified both facts.)
- The `core` record is immutable; resize/reset/clear-reallocation build a fully
  populated new core and commit with **one** field assignment (consistency for
  snapshots, exception-atomicity, and no torn ctrl/keys/mask pairing —
  REV semantics#3/#4, oxcaml#3).
- ctrl encoding (ALG §1): `EMPTY = 0xFF`, `DELETED = 0x80`, `FULL = h2`.
- `keys`/`vals`: Obj.t arrays, `Obj.repr ()` in non-FULL slots; element-boundary
  `Obj.repr`/`Obj.obj`. Known cost (REV oxcaml#6, verified in asm): generic-array
  accesses carry a per-access float-tag check; bench will quantify; candidate
  later optimization is one interleaved 2·buckets array — never magic'd typed
  arrays.
- **Publish ordering (REV semantics#4):** insert writes `keys.(i)`/`vals.(i)`
  *before* flipping ctrl to FULL; erase flips ctrl to EMPTY/DELETED *before*
  dummying the slots. So ctrl=FULL ⟹ well-typed slot, always.
- **No scrubbing of retired generations (REV algorithm#2):** the GC-hygiene
  dummy-overwrite rule applies to the *live* core only. A replaced core's arrays
  are never written again (live `to_seq`/`iter` captures may still read them).
- `length t = t.items + t.nshadow` — O(1).
- Buckets: power of two ≥ 8 (default floor 16, §8).

### Snapshot discipline (REV semantics#3, oxcaml#2 — memory-safety contract)

Every operation reads `t.core` into a local **exactly once** at entry and never
re-reads it after any call into user code (`eq`, user `hash`, traversal `f`,
seq forcing). All array reads AND writes go through that snapshot; `land`-masking
always uses the snapshot's own `mask`. Scalar counters (`items`, `growth_left`,
`nshadow`) and `t.shadow` are accessed through `t`. Effect: a reentrant
resize/reset from user code leaves the running operation working on the
orphaned-but-intact old core — memory-safe, semantically unspecified (matching
stdlib's de-facto behavior); writes to an orphaned core are lost-but-safe.
Mutating ops re-check `t.core == snapshot` (physical equality) before committing
counter updates; on mismatch the counter update is skipped. The identity check
alone only catches whole-core swaps, not a nested operation committing to the
SAME core (REV-impl finding: a self-reentrant `remove` double-decremented
`items`); therefore per-slot commits are additionally **pre-state gated**:
`erase` is a no-op unless the slot's ctrl byte is FULL on entry, and
`do_insert` skips counter updates when the chosen slot was already FULL
(overwriting the slot only). This makes per-slot commits idempotent, so
counters stay coherent with the live core even under reentrant misuse; the
semantic outcome remains "unspecified". The probe invariant check
(`stride <= buckets`) is a real raise in release builds so a
hypothetically-corrupted table raises instead of spinning.

### Hash and split

- Generic interface: `h = seeded_hash_param 10 100 t.seed key` (external
  `caml_hash_exn` exactly as stdlib, API §2.5 — already Murmur3-finalized, used
  as-is).
- Functor-supplied hashes get a single-multiply Fibonacci finalizer:
  `(h * 0x2545F4914F6CDD1D) lsr 33 land 0x3FFFFFFF`. Without it, h2 (bits
  23..29) is all-zero for low-entropy user hashes — including the mli's own
  `let hash i = i land max_int` example — nullifying the tag filter (measured
  9.6 eq calls/miss vs 0.08; REV-impl finding). One multiply per op, removes
  the failure mode entirely.
- `h2 = (h lsr 23) land 0x7f`; probe start `pos = h land mask` (ALG §3).

### Group abstraction

**Instantiation mechanism (post-NEON):** the engine lives in
`lib/core/engine_template.inc`, pasted by dune rules together with a group
implementation (`lib/core/group_swar.inc` → library `swiss`,
`lib_neon/group_neon.inc` → library `swiss_neon`, native-only) into one
generated compilation unit per instantiation, with a
`module _ : Swiss_core.Core_impl.GROUP = G` conformance check. Textual
same-unit pasting is load-bearing: flambda2 does not inline a functor
application of this size (G.* stay indirect calls, measured ~8% slower), and
cross-unit calls returning unboxed tuples compile to uninlined `caml_apply`
(verified by disassembly). Shared mutable state (randomization) stays in
`Swiss_core.Core_impl`. The GROUP contract returns opaque-format native-int
masks via unboxed tuples; each implementation supplies its own mask-iteration
helpers.

8-wide SWAR on `int64`, exact hashbrown formulas (ALG §2), all `[@inline]`.
Loads always little-endian: `external get64 : bytes -> int -> int64 =
"%caml_bytes_get64u"` + `external swap64 : int64 -> int64 = "%bswap_int64"`
guarded by `Sys.big_endian` (REV oxcaml note: `Int64.byteswap` does not exist in
this stdlib; `%bswap_int64` is what stdlib's own `get_int64_le` uses). Mask
iteration in native-int domain after `Int64.to_int (Int64.shift_right_logical m
7)` (bit-63 truncation hazard, ALG §2).

**Allocation-freedom discipline (post-code-review):** the hot probe walks must
be flat `while`-loops over local int refs. Inner `let rec` loops survive
flambda2 closure conversion as per-call heap closures (measured 10 minor
words per find, 25 per replace before the fix), and an `int64` group word
live across an `eq` call gets boxed per probed group. Rule: derive every
needed mask as a native int immediately after `Group.load`; the `int64` must
be dead before any user-code call; no closures in the walk. Verified by
`bench/allocprobe.ml` (0.00 minor words/op for mem/find/replace, parity with
stdlib).
`set_ctrl core i c`: `ctrl.[i] <- c; ctrl.[((i-8) land mask) + 8] <- c`.
NEON 16-wide variant implements the same module signature later (simd.md).

## 3. Multi-binding: the shadow design

The flat table holds exactly the current (most recent) binding per distinct key.
Older bindings live in a side table `shadow : ('a, ('a*'b) list) t option`
mapping key → stack of (key_obj, value), top = second-most-recent; created
lazily on first duplicate; **dropped (set to `None`) whenever `nshadow` returns
to 0** (REV: keeps clean tables at zero traversal/lookup overhead). Stacks are
immutable lists, never empty (REV semantics#7: an entry whose stack would become
`[]` is removed from the shadow table). Lists are rebuilt, never mutated →
structural sharing across `copy` is safe.

The shadow table is used strictly in single-binding mode (only `replace`-style
upsert / `remove` of whole entries), so its own `shadow` stays `None` forever.

**Layering (REV oxcaml#5, verified):** `('a,'b) shadow` makes `t` non-regular,
so recursive definitions need polymorphic recursion. Structure the code as a
flat single-binding core (probe/insert/erase/rehash/copy_core/iter_core …) of
ordinary polymorphic functions, instantiated by the multi-binding layer at both
`('a,'b)` and `('a, ('a*'b) list)`. No polymorphic recursion anywhere (except
possibly `copy`, which may instead call the flat copy at both instances).

### Insert policy (REV algorithm#3 — probe-first, no upfront reserve)

The upsert walk runs **without reserving**:
- key **present** at slot i → shadow push (`add`) or overwrite (`replace`);
  never reserves, never resizes. Duplicate adds at full load are free.
- key **absent** → remembered first empty-or-deleted slot (one walk, ALG §6/§8;
  stop only at a group containing EMPTY): if that slot is DELETED, or
  `growth_left > 0`, insert directly (publish order §2; DELETED reuse does not
  touch `growth_left`; EMPTY consumes one). Else `reserve 1`
  (grow/same-size-rehash per ALG §5 heuristic) and re-probe from scratch.

### Operation mapping

- **find / find_opt / mem**: plain probe; slot value = most recent binding.
  `find` raises `Not_found` on miss. Shadow never consulted.
- **add k v**: upsert walk (stored-key-first equality, §5). Present at i with
  (k0,v0): push `(k0,v0)` on k's stack (create shadow table if None);
  `keys.(i) <- Obj.repr k` (new key object becomes current, like stdlib's fresh
  Cons head); `vals.(i) <- Obj.repr v`; `nshadow+1`. Absent: insert per policy.
- **replace k v**: upsert walk; present → overwrite `keys.(i)`/`vals.(i)` in
  place (API §2.6: position kept, key object overwritten, stack untouched);
  absent → insert.
- **remove k**: probe; miss → no-op. Hit at i:
  - stack for k exists → pop `(k1,v1)` into the slot (`keys.(i) <- Obj.repr k1`
    etc.), `nshadow-1`; ctrl untouched (slot stays FULL — h2 unchanged is valid
    because equal ⟹ hash-equal pins h2). If the stack becomes empty, delete k's
    entry from the shadow table (lookup by the probe key). If `nshadow` hits 0,
    `shadow <- None`.
  - no stack → erase: ctrl→EMPTY/DELETED by the group rule (ALG §6), THEN dummy
    the slots; `items-1`; `growth_left+1` iff EMPTY.
- **find_all k**: probe; `[]` on miss; else
  `Obj.obj vals.(i) :: List.map snd stack` (most-recent-first; no re-`equal` on
  stack entries, §1 deviations).
- **iter / fold — two-phase, zero hash calls (REV oxcaml#7 fix adopted):**
  phase 1: linear scan of the snapshot's ctrl; visit every FULL slot's
  (key, val). Phase 2 (only if a shadow snapshot exists): linear scan of the
  shadow table's own flat slots; for each (k, stack) emit the stack entries in
  order. Per-key most-recent-first holds (slot binding precedes its stack;
  stack is ordered); global order deterministic for non-randomized tables;
  stdlib's traversals-never-hash property is preserved, and mutated-in-place
  keys cannot cause skipped bindings.
- **stats — no hashing:** `num_bindings = length`; `num_buckets = buckets`;
  per-distinct-key "bucket length" = 1 + its stack length, computed two-phase:
  walk shadow's flat slots for `histo.(1+len)`, then
  `histo.(1) += items − shadow.items`, `histo.(0) = buckets − items`.
- **filter_map_inplace f**: linear scan of snapshot; for FULL slot i, loop:
  apply `f k v` to the slot binding; `Some v'` → `vals.(i) <- Obj.repr v'`
  (key NOT rewritten, API §2.12); `None` → pop k's stack into the slot if
  nonempty (deleting the entry when it empties) **and re-apply f to the
  surfaced binding** (each binding presented exactly once); stack exhausted →
  erase (group rule) and advance. Then filter the *remaining* stack in order
  (fresh list; `None` drops with `nshadow-1`; empty result deletes the entry;
  `nshadow = 0` drops the shadow table). Deletions never reserve; `growth_left`
  monotone during the scan (REV algorithm verified the mirror-byte writes can't
  skip/re-present slots). Uses keyed shadow lookups (hash calls — §1 deviation).
- **clear**: full refill (`ctrl` all 0xFF in place, slots dummied, counters
  reset, `shadow <- None`, `growth_left = capacity`) — capacity retained.
  No-op shortcut only when `growth_left = capacity && nshadow = 0` (true
  emptiness incl. no tombstones, REV oxcaml#8).
- **reset**: fresh core at `initial_buckets` (single commit), counters reset.
- **copy**: new core with `Bytes.copy`/`Array.copy` of the snapshot; shadow
  deep-copied as a table (its arrays copied, stacks shared); all scalar fields
  copied including `growth_left` and `initial_buckets`.
- **to_seq**: capture the core snapshot (and the shadow table reference)
  eagerly at call time; lazy two-phase walk as in iter, reading shadow stacks
  from the shadow table's *own* snapshot taken at first force of phase 2.
  Memory-safe under mutation via §2 snapshot rules (orphaned cores are never
  scrubbed); semantics under mutation unspecified, as documented.
- **add_seq/replace_seq/of_seq**: literal stdlib definitions (API §2.14, §2.17).
- **rebuild ?random t — hash-independent enumeration (REV semantics#1):**
  never performs keyed lookups on the source. New table:
  `buckets' = max 16 (source buckets)`, `initial_buckets' = source's
  initial_buckets`, seed fresh iff `random` (default `is_randomized ()`) else
  source's seed (API §2.15). Pass 1: linearly scan the source *shadow* table's
  flat slots; for each (k, stack) `add` the stack entries **oldest-first**
  (`List.rev`). Pass 2: linearly scan the source's flat slots; `add` each
  (k, v) — lands as most recent. Recency preserved per key; works even when the
  source was laid out by a different hash function (the rebuild use case).
  First validates representation shape (Obj.size = the record's field count,
  `core` a 4-field block whose ctrl is Bytes of length mask+1+8) and raises
  `Invalid_argument "Swiss: unsupported hash table format"` otherwise (§1).

### Resize

Trigger only from the insert-absent path (§3 policy): `reserve 1` when
`growth_left = 0` and the chosen slot is EMPTY. Heuristic per ALG §5:
`items + 1 <= capacity/2` → same-size copying rehash (tombstone purge), else
grow. Copying rehash/resize: build the fully-populated new core (re-hash keys;
fresh table → first-empty inserts), compute `growth_left = capacity − items`,
then **single `t.core <-` commit** (a raising user hash mid-rehash leaves the
table untouched — REV oxcaml#3). Shadow table untouched by resize (keyed by
key, not slot). Retired core never written (REV algorithm#2).

## 4. Randomization (API §2.3, replicated verbatim)

`randomized : bool Atomic.t` initialized from `'R' ∈ OCAMLRUNPARAM|CAMLRUNPARAM`;
`randomize`/`is_randomized` trivial; `Rng` = `Domain.Safe.DLS.new_key
Random.State.make_self_init` + `Obj.magic_uncontended` 30-bit draws — REV
verified this exact idiom compiles in user code under a `@@ portable` mli.

## 5. Functors (API §2.16–2.18)

Core parameterized by seeded hash + equal. Equality argument orders replicated
per operation (API §2.4/§2.16): `find`/`find_opt` query-first;
`remove`/`find_all`/`replace`/`mem` stored-first; **`add` (no stdlib precedent —
it shares the upsert walk with `replace`) is pinned stored-first** (REV).
Shadow-table internal operations use the same `equal`/seeded-hash with the same
seed as the parent. `MakeSeeded(H)` / `Make(H)` (seed-ignoring wrapper,
`create ~random:false`, redefined `of_seq`) / `MakePortable` /
`MakeSeededPortable` per API; share the core if the mode checker accepts,
else duplicate bodies like stdlib; `[@@inline available]` on all four.

## 6. Safety rules (consolidated)

1. Snapshot discipline of §2 — single core read per op; no field re-read after
   user code; reads and writes through the snapshot only; commit-check on
   counters.
2. Publish ordering — ctrl=FULL ⟹ slot holds real key/val (§2); erase flips
   ctrl first. No user code runs between slot writes and their set_ctrl.
3. Retired cores are never written.
4. Single-commit core swaps; resize builds fully before committing.
5. All unsafe indexing masked with the *snapshot's* mask; ctrl group loads stay
   within `buckets + 8` (max window start = mask).
6. Never `Int64.to_int` a raw SWAR mask (`lsr 7` first).
7. `stride <= buckets` raise kept in release.
8. Exceptions from user code (`eq`/`hash`/`f`) propagate with coherent state:
   counters committed only adjacent to their structural change, never deferred
   across user calls.

## 7. Build layout

As before (`swiss/lib`, `test`, `bench`); toolchain = nix `result/bin` via
`swiss/env.sh` (verified working). Native + bytecode for the SWAR core.

## 8. Sizing (exact, clamp-never-raise — REV semantics#6, oxcaml#4)

```
max_buckets = largest power of two <= Sys.max_array_length   (* 2^45 here *)
buckets_for_capacity cap =                  (* cap >= 1 *)
  if cap <= 7 then 8
  else if cap >= max_buckets / 8 * 7 then max_buckets        (* clamp, no raise *)
  else next_pow2 (cap * 8 / 7)              (* floor-then-next-pow2, ALG §7 *)
create n: initial_buckets = max 16 (buckets_for_capacity (max n 1))
```
`create`/`rebuild` never raise on size (stdlib parity). The hard wall (insert at
`max_buckets` with `growth_left = 0`, no tombstones) raises `Out_of_memory`,
implemented in `reserve_grow` as `if capacity_of_buckets nb <= items then raise
Out_of_memory` before allocating — stdlib would have OOMed far earlier;
unreachable in practice (≥ 2^45·7/8 entries). Resize growth target per ALG §5
with the same clamp. `rebuild` additionally validates vals/shadow shape and
walks shadow stacks defensively (fail-closed on foreign/corrupted unmarshaled
values).

## 9. Testing strategy

As rev 1, plus (from REV):
- Fuzzer oracle exclusions: cyclic keys / closure-bearing keys for `add`
  (documented deviation), non-equivalence `equal`, side-effecting hash with
  `filter_map_inplace`.
- Invariant checker additions: no empty shadow stacks; `shadow = None` when
  `nshadow = 0`; every shadow key present in the flat table; ctrl=FULL ⟹
  non-dummy slot; `growth_left = capacity − items − tombstones`.
- Targeted regressions for each REV finding: rebuild-after-hash-change
  (simulate by marshaling between differently-seeded functor instances is NOT
  possible — instead unit-test rebuild's two-pass enumeration directly: build
  a table whose shadow lookup with a wrong seed would miss, e.g. construct via
  add ladder, corrupt... simplest: verify rebuild output equality + recency on
  duplicate-rich tables, and that rebuild never calls H.seeded_hash on the
  SOURCE's entries with the source's seed — use a counting hash);
  reentrant `f`/`equal` calling reset/resize mid-op (must not crash; table in
  *some* coherent state); to_seq forced across a resize (no crash, no type
  confusion); filter_map_inplace emptying stacks (invariant checker clean);
  duplicate add at full load (no resize); clear-after-tombstone-churn followed
  by insert (no immediate rehash); create with huge n (no raise).
- Two-phase iter zero-hash property: counting hash sees 0 calls from
  iter/fold/to_seq/stats.

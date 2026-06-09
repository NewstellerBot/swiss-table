# Swiss Table Algorithm Specification — Pure OCaml, 64-bit SWAR, 8-slot groups

**Verified sources (all read directly, not from memory):**

- hashbrown master @ commit `b53fea62820b537a08c99ad44ae111197660816f` (cloned 2026-06-09). Current layout: `src/control/tag.rs`, `src/control/group/generic.rs`, `src/control/bitmask.rs`, `src/raw.rs`. Permalink base: `https://github.com/rust-lang/hashbrown/blob/b53fea62820b537a08c99ad44ae111197660816f` (abbreviated **HB** below).
  - Path history (verified via GitHub API): v0.14.x had `src/raw/generic.rs`, `src/raw/bitmask.rs`, `src/raw/mod.rs`; v0.15.x–v0.17.1 have `src/control/` + `src/raw/`; master has merged `src/raw/mod.rs` into `src/raw.rs`. The constants and SWAR formulas below are from master; the EMPTY/DELETED encodings and SWAR formulas are unchanged from the older layouts (same bit patterns appear in v0.14.5 `src/raw/generic.rs`).
- Abseil master @ commit `d851fdd768b27c02b3fb786fd0987faddd279ece`. `absl/container/internal/hashtable_control_bytes.h` (ctrl encoding + portable SWAR group, moved out of `raw_hash_set.h`), `absl/container/internal/raw_hash_set.h` (H1/H2, probe, capacity). Permalink base **ABSL**.
- OCaml `runtime/hash.c` (trunk): `caml_hash` ends with `FINAL_MIX(h); return Val_int(h & 0x3FFFFFFFU);` — **`Hashtbl.hash` returns exactly 30 well-mixed (Murmur3-finalized) bits, values in `[0, 2^30-1]`**.

Throughout: `GROUP_WIDTH = 8`, table sizes are powers of two with `buckets >= 8`, `mask = buckets - 1`. OCaml `int64` ops written with `L` suffix.

---

## 1. Control byte encoding

### hashbrown (HB `/src/control/tag.rs#L9-L31`)

| state | byte | pattern |
|---|---|---|
| `EMPTY` | `0xFF` | `0b1111_1111` |
| `DELETED` (tombstone) | `0x80` | `0b1000_0000` |
| `FULL(h2)` | `0x00..0x7F` | `0b0xxx_xxxx` (h2 is 7 bits) |

Predicates (tag.rs L16-L31):
- `is_full c = (c land 0x80) = 0`
- `is_special c = (c land 0x80) <> 0`
- `special_is_empty c = (c land 0x01) <> 0` — given `is_special`, bit 0 distinguishes EMPTY (1) from DELETED (0).

**Why the top bit is the load-bearing choice for SWAR:** every special byte has MSB=1 and every full byte has MSB=0 with a 7-bit payload. Therefore:
1. `match_empty_or_deleted` is a single AND with `0x8080808080808080` (one instruction).
2. A full byte (`< 0x80`) can never alias a special byte, so `h2` needs no reserved values inside its 7-bit space.
3. The SWAR equality trick's false positives (see §2) can never fire on EMPTY/DELETED: for a query tag `t < 0x80`, `special ^ t` has MSB=1, so it can be neither `0x00` (true match) nor `0x01` (the only false-positive pattern).
4. hashbrown's specific choice of EMPTY=`0xFF`/DELETED=`0x80` (vs Abseil's) additionally makes `match_empty` one shift+two ANDs (EMPTY is the only special with bit 6 set, see §2), and `special_is_empty` a 1-bit test.

### Abseil differs (ABSL `/absl/container/internal/hashtable_control_bytes.h#L184-L187`)

```cpp
enum class ctrl_t : int8_t {
  kEmpty = -128,   // 0b10000000
  kDeleted = -2,   // 0b11111110
  kSentinel = -1,  // 0b11111111
};
```
Abseil swaps the roles (its EMPTY is hashbrown's DELETED pattern and vice-versa, almost) and adds **kSentinel** at `ctrl[capacity]`; its capacities are `2^n - 1` (`IsValidCapacity(n) := ((n+1) & n) == 0`, raw_hash_set.h L388) and its iterators stop when they hit the sentinel. The sentinel costs a third special value, forces the `kEmpty < kSentinel && kDeleted < kSentinel` ordering constraints (hashtable_control_bytes.h L195-L211), and complicates `MaskEmpty` (`ctrl & ~(ctrl << 6) & msbs`, L468-L470).

**Recommendation: use hashbrown's encoding** (`EMPTY=0xFF`, `DELETED=0x80`, `FULL=h2`). Justification: (a) no sentinel needed — we control iteration and can simply scan `ctrl[0..buckets-1]` for full bytes, as hashbrown does; (b) cheapest `match_empty`/`special_is_empty`; (c) the empty table ctrl array is `Bytes.make (buckets+8) '\xff'` — a single fill; (d) it is the encoding the formulas in §2 are written for.

---

## 2. Exact SWAR formulas (HB `/src/control/group/generic.rs`)

On 64-bit targets `GroupWord = u64`, `Group::WIDTH = 8` (generic.rs L8-L21, L50). All operations are full 64-bit. **OCaml warning: a 63-bit native `int` CANNOT hold these words — bit 63 (the MSB of byte 7) is essential. Use `int64` for the group word and all masks.** (See "OCaml notes" below for how to get back into `int` safely.)

Constants:
```
lsbs = 0x0101010101010101L          (* repeat 0x01 *)
msbs = 0x8080808080808080L          (* repeat 0x80 = repeat DELETED; hashbrown's BITMASK_MASK, generic.rs L27 *)
repeat (b : byte) : int64 = Int64.mul (Int64.of_int b) lsbs   (* generic.rs L31-L34: from_ne_bytes([b;8]) *)
```

Let `g : int64` be 8 control bytes loaded **little-endian** from `ctrl[pos..pos+7]` (so byte at memory offset `i` occupies bits `8i..8i+7`).

### match_byte(h2) — generic.rs L104-L110
```
let cmp = Int64.logxor g (repeat h2) in
let m = Int64.logand (Int64.logand (Int64.sub cmp lsbs) (Int64.lognot cmp)) msbs
```
(`Int64.sub` is wrapping, matching Rust's `wrapping_sub`.) Bit `8i+7` of `m` is set when byte `i` *may* equal `h2`. This is the classic zero-byte detector from Stanford bithacks ("Determine if a word has a byte equal to n" — cited by both hashbrown generic.rs L106-L107 and Abseil hashtable_control_bytes.h L450-L452).

**False-positive caveat (exact semantics, hashbrown comment L97-L103 / Abseil L454-L457):** per byte without borrow the test is exact; but a true match in byte `i` (cmp byte `0x00`) makes the subtraction borrow into byte `i+1`, and if cmp byte `i+1` is `0x01` (ctrl byte differs from `h2` only in its lowest bit) byte `i+1` is falsely reported. Properties: false positives (a) occur only when there is at least one true match below them, (b) never occur on EMPTY/DELETED (their cmp bytes have MSB set, so are neither `0x00` nor `0x01`), (c) chance < 1% per tag. **How hashbrown handles it: it doesn't suppress them — every match candidate is confirmed by full key equality (`eq`) anyway** (raw.rs `find_inner` L2030-L2038). Your implementation MUST therefore never use `match_byte` results without an `eq` confirmation, and never use the popcount of the mask for anything.

### match_empty — generic.rs L114-L120
```
let m = Int64.logand (Int64.logand g (Int64.shift_left g 1)) msbs
```
Works because among bytes with MSB set, only EMPTY (`0b11111111`) also has bit 6 set; `g << 1` lifts bit 6 of each byte into bit 7 (cross-byte spill of each byte's bit 7 lands in the neighbor's bit 0, which the `msbs` mask discards).

### match_empty_or_deleted — generic.rs L124-L128
```
let m = Int64.logand g msbs
```

### match_full — generic.rs L131-L134
```
let m = Int64.logxor (Int64.logand g msbs) msbs      (* = match_empty_or_deleted ^ BITMASK_MASK *)
```

### convert_special_to_empty_and_full_to_deleted — generic.rs L140-L151 (used by rehash-in-place)
Maps EMPTY→EMPTY, DELETED→EMPTY, FULL→DELETED:
```
let full = Int64.logand (Int64.lognot g) msbs in      (* 0x80 in full bytes, 0x00 in special bytes *)
let g' = Int64.add (Int64.lognot full) (Int64.shift_right_logical full 7)
```
Per byte: full → `~0x80 + 1 = 0x80` (DELETED); special → `~0x00 + 0 = 0xFF` (EMPTY). No cross-byte carries occur (`0x7f + 1` stays in-byte). (Abseil's portable equivalent, hashtable_control_bytes.h L492-L497, has an extra `& ~lsbs` because its target encodings differ: `(~x + (x >> 7)) & ~lsbs` with `x = ctrl & msbs`.)

### Mask iteration and endianness — bitmask.rs L24-L78, generic.rs L43-L46
Result masks have at most one bit per byte, at positions `8i+7`. Iteration protocol (hashbrown `BitMaskIter`, bitmask.rs L98-L107):
- slot offset of lowest match: `trailing_zeros64 m / 8` (bitmask.rs L49-L60);
- lowest bit isolate: `m land (-m)` i.e. `Int64.logand m (Int64.neg m)`;
- remove lowest: `m land (m - 1)` i.e. `Int64.logand m (Int64.sub m 1L)` (bitmask.rs L27-L29);
- `leading_zeros64 m / 8` counts non-matching bytes from the TOP of the group (used by deletion, §6); for `m = 0` both counts are 8 (64/8).

**Endianness:** hashbrown loads in native endianness and applies `.to_le()` before constructing the BitMask (generic.rs comment L43-L46) so that low mask bits = low memory addresses. **For OCaml, sidestep this entirely: always load the group with explicit little-endian semantics** (`Bytes.get_int64_le`, or `external unsafe_get64 : bytes -> int -> int64 = "%caml_bytes_get64u"` plus `Int64.byteswap`... actually wrap as `if Sys.big_endian then swap64 (raw) else raw` — `Sys.big_endian` is constant-folded). Then `trailing_zeros/8` gives the slot offset on every platform, including your little-endian arm64 (where the LE load is free). What would change on big-endian **only if** you used native loads: byte 0 would sit in the most-significant position, so you'd need `leading_zeros/8` for the lowest slot and `leading/trailing` would swap everywhere — don't do that; use LE loads unconditionally.

**OCaml 63-bit int notes (implementation-critical):**
- Never `Int64.to_int` a raw mask: bit 63 (slot 7's match bit) is destroyed by the 63-bit truncation. Safe idiom: `let mi = Int64.to_int (Int64.shift_right_logical m 7)` — bits move to positions `0,8,...,56`, which fit exactly in a native `int`; then iterate in `int` domain (`mi land (-mi)`, `mi land (mi-1)`), with slot offset = `tz mi / 8`.
- OCaml has no stdlib ctz. For v1 a byte-stepping loop is fine and branch-predictable (`while v land 0xff = 0 do v := v lsr 8; incr k done`, ≤ 8 iterations, only entered when a match exists); a de Bruijn multiply is an optional optimization.
- `0x8080808080808080` cannot be written as a native-int literal (needs bit 63); as `int64` it's fine (`0x8080808080808080L`).

---

## 3. Hash splitting: h1 / h2

### What the real implementations do
- hashbrown: `h1(hash) = hash as usize` — probe start = `h1 land bucket_mask`, i.e. **low bits** (raw.rs L60-L63, L2449-L2456). `h2 = Tag::full(hash)` = **top 7 bits**: `(hash >> (64-7)) & 0x7f` = `hash >> 57` on 64-bit (tag.rs L35-L49; the `MIN_HASH_LEN` dance only matters for 32-bit `usize` hashers).
- Abseil (current master): identical split — `H1(hash) = hash`, `H2(hash) = hash >> (sizeof(size_t)*8 - 7)` (raw_hash_set.h L759-L764). (Older Abseil used `H2 = hash & 0x7F`, `H1 = hash >> 7`; both schemes keep index bits and h2 bits disjoint, just from opposite ends.)

### The OCaml problem
`Hashtbl.hash` yields only bits 0..29 (verified: `runtime/hash.c` returns `h & 0x3FFFFFFF` after a Murmur3 `FINAL_MIX`). Taking hashbrown's literal `h >> 57` would make **every h2 = 0**: `match_byte` would match every full slot in the probe chain and the table degrades to linear scan with full key comparison. You must re-anchor the split to the 30-bit window.

### Why overlap is bad (explicit tradeoff)
All keys that collide on the probe start share index bits `0..k-1` (for `2^k` buckets). If h2 were derived from those same bits, colliding keys would also share h2, so `match_byte` distinguishes nothing exactly where discrimination is needed — h2's entire purpose (≈ 1/128 false-candidate rate, so ~1 `eq` call per probe group) is defeated. Correctness is never at stake (eq always verifies); only the false-candidate rate degrades.

### Recommendation (v1): disjoint bit extraction, no re-mix
```
let h  = Hashtbl.hash key                  (* in [0, 2^30) — mask with 0x3FFFFFFF defensively if hash is user-supplied *)
let h2 = (h lsr 23) land 0x7f              (* top 7 of the 30 bits: bits 23..29 *)
(* probe start *) let pos = h land mask    (* low k bits: bits 0..k-1 *)
```
- Mirrors hashbrown's structure ("top 7 for h2, low bits for index") shifted to a 30-bit hash.
- **Disjoint for all `k <= 23`**, i.e. up to `2^23 = 8,388,608` buckets = max capacity 7,340,032 entries. Below that, h2 and index share zero bits and Murmur3-mixed bits are uniform/independent — this is exactly as good as hashbrown with a 64-bit hash.
- For `k ∈ (23, 30]`: `k+7 > 30`, so overlap is **unavoidable by any scheme** — 30 input bits simply cannot supply k index bits + 7 independent tag bits. Behavior degrades gracefully: the overlapping high index bits are fixed per probe-start, so h2 effectively loses `k-23` of its 7 bits within one chain (at `k=30`, h2 is fully determined per start group → linear-scan behavior within chains, still correct).
- Hard ceiling: beyond `2^30` buckets the probe start itself can't address all groups. Stdlib `Hashtbl` has the same 30-bit ceiling; document it (capacity > ~7.3M entries means degraded tag filtering, > 2^30 buckets unsupported).

**Considered and rejected for v1 — re-mixing** (e.g. Fibonacci-style `let m = (h * 0x2545F4914F6CDD1D) land max_int` then taking index and h2 from disjoint high bit-ranges of `m`): it cannot create entropy beyond the 30 input bits, only smears the >8M-bucket degradation into correlation instead of determinism; it costs a multiply on every operation; and the natural 64-bit constant `0x9E3779B97F4A7C15` doesn't even fit OCaml's 63-bit int. The right fix for users with huge tables is a functorized 63-bit `hash` (then use literal hashbrown splitting: `h2 = (h lsr 56) land 0x7f`, `pos = h land mask`). Note `0x2545F4914F6CDD1D` *does* fit in 63 bits if you later want the mixer as an option.

---

## 4. Probe sequence and the mirrored control tail

### Triangular probing over groups (raw.rs L65-L93, L2449-L2456; Abseil raw_hash_set.h L1703-L1727 is identical)
```
state: pos, stride
init:  pos    = h land mask          (* h1 masked *)
       stride = 0
step:  stride <- stride + 8          (* + GROUP_WIDTH *)
       pos    <- (pos + stride) land mask
```
Each iteration loads the 8-byte group window starting at `pos` (windows are *unaligned* — `Group::load` is `read_unaligned`, generic.rs L72-L74). Visit sequence: `pos_i = (h1 + 8*T_i) mod 2^k` where `T_i = i(i+1)/2`.

**Proof sketch that all groups are visited (hashbrown cites https://fgiesen.wordpress.com/2015/02/22/triangular-numbers-mod-2n/, raw.rs L72-L73):** with `2^k` buckets and width 8, the start offsets are `h1 + 8*T_i (mod 2^k)`; it suffices that `T_i mod 2^(k-3)` hits every residue for `i = 0..2^(k-3)-1`. Suppose `T_i ≡ T_j (mod 2^m)`. Then `i(i+1) ≡ j(j+1) (mod 2^(m+1))`, i.e. `(i-j)(i+j+1) ≡ 0 (mod 2^(m+1))`. `i-j` and `i+j+1` have opposite parity, so the odd one is invertible mod `2^(m+1)`, forcing the other ≡ 0 mod `2^(m+1)`; since `0 <= i,j < 2^m` we have `|i-j| < 2^m` and `0 < i+j+1 < 2^(m+1)`, so both cases force `i=j`. Hence the `2^(k-3)` start offsets are distinct and spaced by multiples of 8 — their 8-wide windows tile the whole table. Termination: the loop must stop at a group containing EMPTY; the 7/8 load factor guarantees one exists. Keep hashbrown's sanity check `assert (stride <= buckets)` (raw.rs L84-L87 asserts `stride <= bucket_mask`).

### Wraparound + cloned tail (raw.rs L2565-L2597, L2651-L2653)
- **ctrl length for `buckets` slots: `buckets + GROUP_WIDTH = buckets + 8` bytes** (`num_ctrl_bytes = bucket_mask + 1 + Group::WIDTH`, raw.rs L2651-L2653). All initialized to EMPTY (`0xFF`).
- The clone region `ctrl[buckets .. buckets+7]` mirrors `ctrl[0 .. 7]` (for `buckets >= 8`). A window starting at `pos = mask` reads `ctrl[buckets-1 .. buckets+6]`; the very last byte `ctrl[buckets+7]` is written but **never read** (max window start is `mask`), kept only to make `set_ctrl` branchless — hashbrown's comment, raw.rs L2574-L2576.
- Candidate indices coming out of a window must be re-masked: `idx = (pos + bit_offset) land mask` (raw.rs L2031-L2033) — that's all the wraparound handling needed.
- **Keeping the mirror in sync — exact formula** (raw.rs L2590-L2595): every control write goes through
```
set_ctrl i c:
  ctrl.[i] <- c;
  ctrl.[((i - 8) land mask) + 8] <- c     (* i.e. ((i - GROUP_WIDTH) mod buckets) + GROUP_WIDTH *)
```
For `i >= 8` the second index equals `i` (idempotent double-write, branchless); for `i < 8` it equals `buckets + i` (the mirror byte). OCaml's `land` on the negative `i - 8` produces the correct mod-2^k result (two's complement). hashbrown also handles `buckets < 8` with permanently-EMPTY filler bytes between the real array and the clone (comment L2578-L2586) — irrelevant for us since we pin `buckets >= 8` (§7).

---

## 5. Capacity, load factor, growth_left, and the grow-vs-rehash decision

- **7/8 rule** (raw.rs L182-L191): `bucket_mask_to_capacity mask = if mask < 8 then mask else (mask+1)/8*7`. With `buckets >= 8` pinned: `capacity = buckets / 8 * 7` (note: for `buckets = 8`, both branches give 7).
- `bucket_mask = buckets - 1`; all index arithmetic is `land mask`.
- **growth_left** (struct field, raw.rs L576): number of inserts into EMPTY slots still allowed. Maintained as:
  - insert: `growth_left -= (old_ctrl was EMPTY ? 1 : 0)` — replacing a DELETED costs nothing (`record_item_insert_at`, raw.rs L2459-L2465; `special_is_empty` = bit-0 test);
  - erase to EMPTY: `growth_left += 1`; erase to DELETED: unchanged (raw.rs L3279-L3284);
  - after any resize/rehash: `growth_left = capacity - items` (raw.rs L3014, L3075, L2946).
  - Invariant: `growth_left = capacity - items - tombstones`.
- **Insert triggers** — two distinct paths in hashbrown:
  - `find_or_find_insert_index` (the map upsert path) calls `reserve(1)` **before** probing; `reserve` does nothing unless `additional > growth_left` (raw.rs L1126, L909-L919).
  - raw `insert` (no existence check) probes first, and only if `growth_left == 0 && old_ctrl is EMPTY` does it reserve and re-probe — i.e. **landing on a tombstone never triggers growth** (raw.rs L1031-L1043, comment L1033-L1034).
- **Grow vs rehash-in-place — the tombstone-reclaim heuristic** (`reserve_rehash_inner`, raw.rs L2740-L2794):
```
new_items = items + additional
full_capacity = bucket_mask_to_capacity mask
if new_items <= full_capacity / 2
  then rehash_in_place ()                     (* same allocation; tombstones dominate *)
  else resize (max new_items (full_capacity + 1))   (* capacity_to_buckets -> next pow2, i.e. 2x buckets *)
```
Rationale: the trigger fired with `items + tombstones >= capacity`, so `items <= capacity/2` implies `tombstones >= capacity/2`.
- Abseil for comparison: `CapacityToGrowth(c) = c - c/8` with `c = 2^n - 1` (raw_hash_set.h L434-L441) — same 7/8 idea, off-by-one different because of the sentinel.

**Recommended v1 policy:** implement exactly hashbrown's heuristic (it's 5 lines), but replace `rehash_in_place` with a **same-bucket-count copying rehash** (allocate fresh ctrl/key/value arrays of the same size, reinsert all live entries — identical code to `resize`, just without growing). This is correct, removes all tombstones, avoids the in-place swap dance (§6), and only costs a transient allocation. Always-grow-on-trigger is *also* correct but can balloon memory under sustained insert/delete churn at constant size — keep the `items <= capacity/2` branch. Spec the true in-place algorithm (below, §8) as a later optimization.

---

## 6. Insert and delete subtleties

### find-or-insert must out-probe tombstones (raw.rs `find_or_find_insert_index_inner` L1796-L1857)
Correct upsert requires, in ONE probe walk:
1. For each group: check `match_byte h2` candidates with `eq` first — the key may exist anywhere along the chain.
2. Remember the **first** EMPTY-or-DELETED slot seen (`find_insert_index_in_group`, L1749-L1759: lowest set bit of `match_empty_or_deleted`, index `(pos + bit) land mask`) — this is the "insert into first tombstone seen" optimization.
3. **Stop only at a group containing an EMPTY byte** (`match_empty <> 0`, L1838-L1852). A group that is all FULL/DELETED does *not* terminate the search: the key may live in a later group (it was inserted past slots that were full at the time and tombstoned since). Stopping at the first tombstone-bearing group and declaring "absent" is THE classic Swiss-table correctness bug.
4. On reaching an EMPTY-bearing group, return the remembered slot (guaranteed `Some` — the current group has an EMPTY which is also empty-or-deleted).

### The end-of-probe full-group edge case (`fix_insert_index`, raw.rs L1710-L1739)
For tables with `buckets < GROUP_WIDTH`, hashbrown's ctrl layout contains permanently-EMPTY filler bytes (between the real bytes and the clone). A window can pick such a filler byte; `(pos + bit) land mask` then maps it to a real slot **that may be FULL**. hashbrown's fix: if the chosen slot is full (only possible when `bucket_mask < Group::WIDTH` — their debug assert L1713), reload the **aligned** group at `ctrl[0]` and take its lowest empty-or-deleted bit.

**For us this is vacuous, by construction:** with `buckets >= 8 = GROUP_WIDTH` there are no filler bytes — the tail is an exact mirror of `ctrl[0..7]`, and any 8-byte window over the `buckets+8` array covers each residue class mod `buckets` at most once with a faithful copy, so a matched empty-or-deleted bit always maps to a genuinely empty-or-deleted slot. (hashbrown's own comment confirms: "for tables larger than the group width we will never end up in the given branch", L1722-L1726. Note their guard `bucket_mask < Group::WIDTH` nominally includes `buckets = 8`, but at 8 buckets the mirror is exact and capacity 7 guarantees an EMPTY, so the fix still cannot trigger — my derivation, flagged in open questions.) **Spec: omit fix_insert_index; keep a debug assertion that the chosen slot is not FULL.**

### Deletion: EMPTY vs DELETED (`erase`, raw.rs L3225-L3290)
When removing the entry at `index` (its ctrl byte is FULL):
```
index_before = (index - 8) land mask                       (* window of the 8 bytes BEFORE index *)
empty_before = match_empty (load ctrl index_before)        (* window covers index-8 .. index-1 *)
empty_after  = match_empty (load ctrl index)               (* window covers index .. index+7 *)
if leading_zero_bytes empty_before + trailing_zero_bytes empty_after >= 8 (* GROUP_WIDTH *)
then set_ctrl index DELETED
else (set_ctrl index EMPTY; growth_left <- growth_left + 1)
items <- items - 1
```
where `leading_zero_bytes m = leading_zeros64 m / 8` and `trailing_zero_bytes m = trailing_zeros64 m / 8` (both = 8 for `m = 0L`). Semantics: `leading_zero_bytes empty_before` = run of consecutive non-EMPTY bytes immediately below `index` (growing downward from `index-1`); `trailing_zero_bytes empty_after` = run starting at `index` growing upward. If the combined run ≥ 8, some 8-byte probe window containing `index` has no EMPTY byte, meaning a past search could have probed *through* this slot — it must become a tombstone so future searches keep going. Otherwise every window containing `index` also contains an EMPTY, so searches would have stopped in that window anyway → safe to mark EMPTY (and reclaim growth). At `buckets = 8`, `index_before = index` and the rule degenerates to "DELETED iff no EMPTY anywhere", which never happens (capacity 7 of 8), so 8-bucket tables never contain tombstones — matching hashbrown's comment L3273-L3275.

**OCaml-specific:** on erase you must also overwrite the key and value slots with a dummy (e.g. `Obj.magic ()` sentinel or your chosen filler) so the GC doesn't retain the removed bindings.

---

## 7. Sizing math

### hashbrown exact (raw.rs L104-L164, L182-L191)
- `capacity_to_buckets cap` (`cap >= 1`):
  - `cap < 15` (small tables): `min_cap` adjusted for allocator-padding edge cases (for `Group::WIDTH = 8`: `min_cap = 7` when element size ≤ 1 byte, else `3`); then `buckets = if cap' < 4 then 4 else if cap' < 8 then 8 else 16`. (2-bucket tables are skipped entirely.)
  - else: `buckets = next_power_of_two (cap * 8 / 7)` — **floor** division; the comment promises `next_power_of_two` cleans up the rounding, and this is provably exact for `buckets >= 8`: if `floor(8c/7)` landed strictly below `8c/7` on a power of two `2^m` (m ≥ 3) we'd need `8c = 7·2^m + s`, `s ∈ 1..6`, with `8 | 8c` and `8 | 7·2^m` — impossible. So the resulting `buckets` always satisfies `buckets/8*7 >= cap`.
- `bucket_mask_to_capacity mask = if mask < 8 then mask else (mask+1)/8*7` (the `mask < 8` branch covers their 1/2/4/8-bucket tables: capacity = buckets - 1).
- Growth target on resize: `max (items + additional) (full_capacity + 1)` (raw.rs L2787) — `+1` forces at least the next power of two.

### Safe simplifications for us (pin `buckets >= 8`, pow2)
```
buckets_for_capacity cap =
  if cap <= 7 then 8
  else if cap > max_int / 8 then invalid_arg "capacity overflow"
  else next_pow2 (cap * 8 / 7)

capacity_of_buckets buckets = buckets / 8 * 7      (* 8 -> 7, 16 -> 14, 32 -> 28, ... *)
```
Safe to drop: the 4-bucket table (we waste 4 slots on tiny tables — acceptable); the `min_cap` element-size adjustment (it exists only to amortize allocator alignment padding for ≤1-byte elements — meaningless for OCaml arrays); the `mask < 8` capacity branch (for `buckets = 8` it coincides with the 7/8 formula). **Not** safe to drop: the floor-then-next-pow2 order (don't "fix" it to ceiling and accidentally jump a size class — e.g. `cap=7`: `ceil` gives 8 buckets just like floor, but `cap=28`: `8*28/7=32` exact, ceiling variants that add before dividing can yield 64); the `+1` in the growth target; the overflow guard.

`next_pow2 n` (n ≥ 1): standard bit-smearing `let n = n-1 in n |> or-shift 1,2,4,8,16,32 |> (+1)`.

---

## 8. Pseudocode reference (8-wide SWAR, little-endian, pow2 buckets ≥ 8)

State: `ctrl : Bytes.t` (length `buckets + 8`, init all `'\xff'`), `keys/vals` (length `buckets`, dummy-filled), `items`, `growth_left`, `mask = buckets - 1`.

Helpers (all from §2):
```
load pos        = get_int64_le ctrl pos                     (* pos in 0..mask; reads <= mask+7 < buckets+8 *)
set_ctrl i c    = ctrl.[i] <- c; ctrl.[((i-8) land mask) + 8] <- c
h2 h            = (h lsr 23) land 0x7f
probe_start h   = h land mask
EMPTY = 0xFF; DELETED = 0x80
```

### find(h, key, eq)  — mirrors `find_inner` (raw.rs L2009-L2046)
```
let tag = h2 h in
let pos = ref (probe_start h) and stride = ref 0 in
let rec loop () =
  let g = load !pos in
  let m = ref (match_byte g tag) in
  while !m <> 0L do
    let off = trailing_zero_bytes !m in
    let idx = (!pos + off) land mask in
    if eq keys.(idx) key then raise (Found idx);
    m := clear_lowest_bit !m
  done;
  if match_empty g <> 0L then None
  else begin
    stride := !stride + 8;
    assert (!stride <= buckets);          (* probe invariant; cannot fire if load factor holds *)
    pos := (!pos + !stride) land mask;
    loop ()
  end
```

### insert / upsert — mirrors `find_or_find_insert_index` (raw.rs L1120-L1145, L1796-L1857)
```
let replace t key value =
  reserve t 1;                                    (* grow/rehash if growth_left = 0; see below *)
  let h = Hashtbl.hash key in let tag = h2 h in
  let pos = ref (probe_start h) and stride = ref 0 in
  let insert_slot = ref (-1) in
  let rec loop () =
    let g = load !pos in
    (* 1: existing key? *)
    iterate match_byte g tag -> idx = (!pos + off) land mask:
      if eq keys.(idx) key then (vals.(idx) <- value; raise Done);
    (* 2: remember FIRST empty-or-deleted slot across the whole walk *)
    if !insert_slot < 0 then begin
      let m = match_empty_or_deleted g in
      if m <> 0L then insert_slot := (!pos + trailing_zero_bytes m) land mask
    end;
    (* 3: stop ONLY at a group containing EMPTY *)
    if match_empty g <> 0L then begin
      let idx = !insert_slot in                  (* guaranteed >= 0 here *)
      assert (Char.code ctrl.[idx] land 0x80 <> 0);     (* never FULL; see §6 *)
      let was_empty = ctrl.[idx] = EMPTY in
      set_ctrl idx tag;
      if was_empty then growth_left <- growth_left - 1;
      items <- items + 1;
      keys.(idx) <- key; vals.(idx) <- value
    end else advance pos stride; loop ()
  in loop ()
```
(Variant matching hashbrown's raw `insert`: skip the upfront `reserve`, and after finding the slot, if `growth_left = 0 && ctrl.[idx] = EMPTY` then `reserve 1` and re-probe — lets tombstone replacement proceed at full load, raw.rs L1031-L1043.)

### remove(h, key, eq)
```
find the index idx as in find;
on found:
  let before = (idx - 8) land mask in
  let eb = match_empty (load before) and ea = match_empty (load idx) in
  if leading_zero_bytes eb + trailing_zero_bytes ea >= 8
    then set_ctrl idx DELETED
    else (set_ctrl idx EMPTY; growth_left <- growth_left + 1);
  items <- items - 1;
  keys.(idx) <- dummy; vals.(idx) <- dummy        (* GC hygiene *)
```

### reserve / resize / rehash — mirrors raw.rs L909-L919, L2740-L2794, L2985-L3078
```
let reserve t additional =
  if additional > growth_left then begin
    let new_items = items + additional in
    let full_cap = buckets / 8 * 7 in
    if new_items <= full_cap / 2
      then rehash_same_size t            (* tombstone purge *)
      else resize_to t (max new_items (full_cap + 1))
  end

let resize_to t cap =
  let nb = buckets_for_capacity cap in
  allocate new ctrl (nb+8, all EMPTY), keys, vals;
  for i = 0 to old_buckets - 1 do
    if ctrl_old.[i] is FULL then
      let h = Hashtbl.hash keys_old.(i) in        (* or reuse a stored hash array, see note *)
      (* find_insert_index in NEW table: probe, take lowest match_empty_or_deleted bit;
         new table has no DELETED, so this is just first-empty *)
      let idx = find_insert_index_new h in
      set_ctrl_new idx (h2 h); move key/val
  done;
  growth_left <- capacity_of_buckets nb - items

(* v1: rehash_same_size = resize_to at the same bucket count (fresh arrays). *)
```
**True in-place rehash** (later optimization; raw.rs L2081-L2119 + L2985-L3078): (1) for each aligned group `i = 0, 8, ..., buckets-8`: `store i (convert_special_to_empty_and_full_to_deleted (load i))`; then repair the tail mirror: `Bytes.blit ctrl 0 ctrl buckets 8`. (2) For each `i` with `ctrl.[i] = DELETED` (these are the not-yet-rehashed live entries): loop — `h = hash keys.(i)`; `new_i = find_insert_index h`; if `((i - probe_start h) land mask)/8 = ((new_i - probe_start h) land mask)/8` (same window-aligned group, raw.rs L2467-L2473) then `set_ctrl i (h2 h)` and next `i`; else if `ctrl.[new_i] = EMPTY` then `set_ctrl new_i (h2 h)`; move slot `i → new_i`; `set_ctrl i EMPTY`; next `i`; else (`= DELETED`) `set_ctrl new_i (h2 h)`; **swap** slots `i ↔ new_i`; repeat the loop for the element now at `i`. (3) `growth_left <- capacity - items`. (hashbrown's panic-guard around the hasher is irrelevant if your hash function cannot raise; OCaml `Hashtbl.hash` cannot.)

---

## Flagged items / could-not-verify

1. **Version skew:** all hashbrown citations are master `b53fea6` (function names there: `find_insert_index`, `fix_insert_index`, `find_or_find_insert_index_inner`; in ≤0.15 they were `find_insert_slot`, `fix_insert_slot`, `find_or_find_insert_slot`). I verified the v0.14.5/v0.15.5 *file layouts* via the GitHub API but did not line-by-line diff older constants; the EMPTY/DELETED patterns and SWAR formulas are stable across versions to my knowledge, and everything in this spec is self-consistent against master.
2. **`buckets = 8` never needs `fix_insert_slot` and never holds tombstones** — my own derivations (§6); hashbrown's guard (`bucket_mask < Group::WIDTH`) nominally includes this size. Both derivations are short and I'm confident, but keep the recommended debug assertions in fuzzing builds.
3. **Int64 performance in OCaml** (boxing of `int64` group words; whether the native compiler's local unboxing suffices without flambda) is a performance question I did not benchmark — correctness is unaffected. The `lsr 7`-then-`to_int` trick (§2) is exact and lets all mask *iteration* happen on native ints.
4. `%caml_bytes_get64u` is native-endian; `Bytes.get_int64_le` byteswaps on BE platforms — verify the exact external you use against the OCaml version you target (safe `get_int64_le` exists since 4.08).
5. Abseil details beyond what's cited (e.g. its small-table `is_small()` mode, growth-info packing) were not fully traced; they don't affect this spec since we recommend the hashbrown design throughout.

## Key permalinks
- Tags: HB`/src/control/tag.rs#L9-L49` — Abseil ctrl_t: ABSL`/absl/container/internal/hashtable_control_bytes.h#L184-L187`
- SWAR group: HB`/src/control/group/generic.rs#L104-L151` — Abseil portable: ABSL`/.../hashtable_control_bytes.h#L439-L500`
- BitMask: HB`/src/control/bitmask.rs#L24-L78`
- h1/h2: HB`/src/raw.rs#L60-L63`, HB`/src/control/tag.rs#L35-L49` — ABSL`/.../raw_hash_set.h#L759-L764`
- Probe: HB`/src/raw.rs#L65-L93`, `#L2449-L2456` — ABSL`/.../raw_hash_set.h#L1703-L1727`
- Sizing: HB`/src/raw.rs#L104-L164`, `#L182-L191` — ABSL`/.../raw_hash_set.h#L388`, `#L434-L441`
- set_ctrl mirror / ctrl length: HB`/src/raw.rs#L2565-L2597`, `#L2651-L2653`
- find / upsert / fix: HB`/src/raw.rs#L2009-L2046`, `#L1796-L1857`, `#L1749-L1759`, `#L1710-L1739`
- reserve & heuristic: HB`/src/raw.rs#L909-L919`, `#L1024-L1047`, `#L2740-L2794`
- erase: HB`/src/raw.rs#L3225-L3290` — rehash in place: HB`/src/raw.rs#L2081-L2119`, `#L2985-L3078`
- OCaml hash truncation: `https://github.com/ocaml/ocaml/blob/trunk/runtime/hash.c` (`return Val_int(h & 0x3FFFFFFFU)` at the end of `caml_hash`, fetched 2026-06-09)

## Open questions (from researcher)
- Whether OCaml's native compiler (without flambda) keeps the int64 group word unboxed in the hot find loop — needs a microbenchmark; if boxing dominates, consider Bigarray (int64, c_layout) for ctrl or a two-uint32-halves SWAR fallback.
- My derivation that buckets=8 (== GROUP_WIDTH) can never trigger hashbrown's fix_insert_slot path and never holds tombstones — hashbrown's own guard (bucket_mask < Group::WIDTH) conservatively includes this size; keep debug assertions during differential fuzzing to confirm.
- Exact line numbers cited are for hashbrown master b53fea62 and Abseil master d851fdd7 (2026-06-09); if the implementer pins a released crate (e.g. hashbrown 0.15.x/0.17.x) the file paths and function names differ slightly (find_insert_slot vs find_insert_index) though constants/formulas are the same.
- Which OCaml version floor to target: Bytes.get_int64_le requires >= 4.08; the unsafe %caml_bytes_get64u primitive is native-endian and needs a Sys.big_endian-guarded byteswap wrapper.
- Whether to store the 30-bit hash per slot (extra int array) to avoid re-hashing keys on resize and to pre-filter eq calls — a design tradeoff left to the parent design task.

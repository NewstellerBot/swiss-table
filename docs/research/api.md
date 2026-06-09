# OxCaml stdlib `Hashtbl` — Exact API + Semantics Specification

**Ground-truth files (all claims cited against these):**

- MLI (contract): `/Users/krystian/code/ocaml-swiss-table/oxcaml/_build/runtime_stdlib_install/lib/ocaml_runtime_stdlib/hashtbl.mli` — verified **byte-identical** (via `diff`) to the source `/Users/krystian/code/ocaml-swiss-table/oxcaml/stdlib/hashtbl.mli`. Citations below as `mli:N` (line 1 of both files is the `# 2 "hashtbl.mli"` line directive).
- Implementation: `/Users/krystian/code/ocaml-swiss-table/oxcaml/stdlib/hashtbl.ml` — cited as `ml:N` (line 1 is `# 2 "hashtbl.ml"`).
- Runtime hash: `/Users/krystian/code/ocaml-swiss-table/oxcaml/runtime/hash.c` — cited as `hash.c:N`.
- Header layout (for `Sys.max_array_length`): `/Users/krystian/code/ocaml-swiss-table/oxcaml/runtime/caml/mlvalues.h`.
- Upstream comparison: diffed against `ocaml/ocaml` branch `5.2` `stdlib/hashtbl.{mli,ml}` (fetched from GitHub; see §3).

---

## 1. Complete exported API (exact signatures)

### 1.0 Module-level annotations (must be reproduced verbatim)

- `mli:17` — the entire interface is declared portable with a bare module-level modality line:
  ```
  @@ portable
  ```
- `mli:19` — `open! Stdlib` (present in mli; also `ml:17`).
- `mli:51–55` — the unsynchronized-access alert, fenced by warning 53 (misplaced-attribute) suppression. Quote exactly:
  ```ocaml
  [@@@warning "-53"]
  [@@@alert unsynchronized_access
      "Unsynchronized accesses to hash tables are a programming error."
  ]
  [@@@warning "+53"]
  ```
  Note: this block (including the warning fencing) is **also present in upstream 5.2** — it is not OxCaml-specific.
- `ml:19` — implementation carries `[@@@ocaml.flambda_o3]` (implementation detail, not part of the interface contract, but note it for build parity).

### 1.1 Types

```ocaml
type (!'a, !'b) t : mutable_data with 'a with 'b
```
(`mli:67`). Both parameters are injective (`!`). The kind annotation `: mutable_data with 'a with 'b` is OxCaml-specific (upstream 5.2 has just `type (!'a, !'b) t`). A reimplementation must have a kind that is a subkind of this (the type must be allowed to cross modes as `mutable_data` does, parameterized by `'a` and `'b`).

```ocaml
type statistics = {
  num_bindings: int;
  num_buckets: int;
  max_bucket_length: int;
  bucket_histogram: int array
}
```
(`mli:265–277`, `ml:243–248`). Doc: `num_bindings` = same value as `length`; `num_buckets` = number of buckets; `max_bucket_length` = maximal bindings per bucket; `bucket_histogram` has length `max_bucket_length + 1`, `histo.(i)` = number of buckets of size `i`. `@since 4.00` on the type (`mli:264`).

### 1.2 Values (generic interface)

All exactly as written in the mli (the `(* thwart tools/sync_stdlib_docs *)` comments are inside the signature source and should be preserved if regenerating the file):

```ocaml
val create : ?random: (* thwart tools/sync_stdlib_docs *) bool -> int -> ('a, 'b) t   (* mli:70-71 *)
val clear : ('a, 'b) t -> unit                                                        (* mli:109 *)
val reset : ('a, 'b) t -> unit                                                        (* mli:113, @since 4.00 *)
val copy : ('a, 'b) t -> ('a, 'b) t                                                   (* mli:118 *)
val add : ('a, 'b) t -> 'a -> 'b -> unit                                              (* mli:121 *)
val find : ('a, 'b) t -> 'a -> 'b                                                     (* mli:133 *)
val find_opt : ('a, 'b) t -> 'a -> 'b option                                          (* mli:137, @since 4.05 *)
val find_all : ('a, 'b) t -> 'a -> 'b list                                            (* mli:142 *)
val mem : ('a, 'b) t -> 'a -> bool                                                    (* mli:148 *)
val remove : ('a, 'b) t -> 'a -> unit                                                 (* mli:151 *)
val replace : ('a, 'b) t -> 'a -> 'b -> unit                                          (* mli:156 *)
val iter : ('a -> 'b -> unit) -> ('a, 'b) t -> unit                                   (* mli:163 *)
val filter_map_inplace: ('a -> 'b -> 'b option) -> ('a, 'b) t -> unit                 (* mli:183-184, @since 4.03 *)
val fold : ('a -> 'b -> 'acc -> 'acc) -> ('a, 'b) t -> 'acc -> 'acc                   (* mli:194-195 *)
val length : ('a, 'b) t -> int                                                        (* mli:217 *)
val randomize : unit -> unit                                                          (* mli:223, @since 4.00 *)
val is_randomized : unit -> bool                                                      (* mli:242, @since 4.03 *)
val rebuild : ?random (* thwart tools/sync_stdlib_docs *) :bool -> ('a, 'b) t -> ('a, 'b) t  (* mli:247-248, @since 4.12 *)
val stats : ('a, 'b) t -> statistics                                                  (* mli:279, @since 4.00 *)
val to_seq : ('a,'b) t -> ('a * 'b) Seq.t                                             (* mli:287, @since 4.07 *)
val to_seq_keys : ('a,_) t -> 'a Seq.t                                                (* mli:298, @since 4.07 *)
val to_seq_values : (_,'b) t -> 'b Seq.t                                              (* mli:302, @since 4.07 *)
val add_seq : ('a,'b) t -> ('a * 'b) Seq.t -> unit                                    (* mli:306, @since 4.07 *)
val replace_seq : ('a,'b) t -> ('a * 'b) Seq.t -> unit                                (* mli:310, @since 4.07 *)
val of_seq : ('a * 'b) Seq.t -> ('a, 'b) t                                            (* mli:314, @since 4.07 *)
val hash : 'a -> int                                                                  (* mli:529 *)
val seeded_hash : int -> 'a -> int                                                    (* mli:535, @since 4.00 *)
val hash_param : int -> int -> 'a -> int                                              (* mli:540 *)
val seeded_hash_param : int -> int -> int -> 'a -> int                                (* mli:559, @since 4.00 *)
```

No per-value mode annotations appear in the mli — every item is portable via the module-level `@@ portable` at `mli:17`.

### 1.3 Module types and functors

```ocaml
module type HashedType = sig
  type t
  val equal : t -> t -> bool
  val hash : t -> int
end
```
(`mli:352–373`). Contract on `hash`: `equal x y` implies `hash x = hash y`.

```ocaml
module type S = sig
  type key
  type !'a t
  val create : int -> 'a t                  (* NOTE: NO ?random parameter *)
  val clear : 'a t -> unit
  val reset : 'a t -> unit                  (* @since 4.00 *)
  val copy : 'a t -> 'a t
  val add : 'a t -> key -> 'a -> unit
  val remove : 'a t -> key -> unit
  val find : 'a t -> key -> 'a
  val find_opt : 'a t -> key -> 'a option   (* @since 4.05 *)
  val find_all : 'a t -> key -> 'a list
  val replace : 'a t -> key -> 'a -> unit
  val mem : 'a t -> key -> bool
  val iter : (key -> 'a -> unit) -> 'a t -> unit
  val filter_map_inplace: (key -> 'a -> 'a option) -> 'a t -> unit  (* @since 4.03 *)
  val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
  val length : 'a t -> int
  val stats: 'a t -> statistics             (* @since 4.00 *)
  val to_seq : 'a t -> (key * 'a) Seq.t
  val to_seq_keys : _ t -> key Seq.t
  val to_seq_values : 'a t -> 'a Seq.t
  val add_seq : 'a t -> (key * 'a) Seq.t -> unit
  val replace_seq : 'a t -> (key * 'a) Seq.t -> unit
  val of_seq : (key * 'a) Seq.t -> 'a t     (* seq vals all @since 4.07 *)
end
```
(`mli:376–421`). **What `S` does NOT expose vs. the toplevel module:** `randomize`, `is_randomized`, `rebuild`, the four hash functions, and `create`'s `?random` parameter.

```ocaml
module Make (H : HashedType) : S with type key = H.t                       (* mli:424 *)

module MakePortable (H : sig @@ portable include HashedType end)
  : sig @@ portable include S with type key = H.t end                      (* mli:436-437, OxCaml-only *)

module type SeededHashedType = sig
  type t
  val equal: t -> t -> bool
  val seeded_hash: int -> t -> int
end                                                                        (* mli:441-455, @since 4.00 *)
```
Contract on `seeded_hash`: `equal x y` implies `seeded_hash seed x = seeded_hash seed y` for **any** seed (`mli:449–454`; the doc xref here is `{!Stdlib.Hashtbl.seeded_hash}` in OxCaml vs `{!Hashtbl.seeded_hash}` upstream).

```ocaml
module type SeededS = sig
  type key
  type !'a t
  val create : ?random (* thwart tools/sync_stdlib_docs *) :bool -> int -> 'a t  (* HAS ?random *)
  (* ... otherwise the same members as S, same order, same @since annotations,
     EXCEPT: stats has no @since comment here (mli:484) and reset has none (mli:466) *)
end                                                                        (* mli:459-503, @since 4.00 *)

module MakeSeeded (H : SeededHashedType) : SeededS with type key = H.t     (* mli:507, @since 4.00 *)

module MakeSeededPortable (H : sig @@ portable include SeededHashedType end)
  : sig @@ portable include SeededS with type key = H.t end                (* mli:521-522, OxCaml-only *)
```
`SeededS` (like `S`) does **not** expose `rebuild`, `randomize`, `is_randomized`, or the hash functions; the only structural difference between `S` and `SeededS` is `create`'s `?random:bool` parameter (`mli:380` vs `mli:463–464`; `ml:309` vs `ml:337`).

### 1.4 Exceptions

No exceptions are declared by the module. Raised exceptions:
- `Not_found` — `find` only (generic: `ml:701,707,711,715`; functor: `ml:399,406,410,414`). `find_opt`/`mem`/`find_all`/`remove` never raise it.
- `Invalid_argument "Hashtbl: unsupported hash table format"` — from the generic `key_index` when `Obj.size (Obj.repr h) < 4`, i.e. when operating on a pre-4.00-format table obtained by unmarshaling (`ml:670–673`). Reachable from generic `add/remove/find/find_opt/find_all/replace/mem`.
- `Invalid_argument "hash: mixed block value"` — from `caml_hash_exn` when hashing an OxCaml mixed block (`hash.c:290–292`). Reachable from `hash`, `seeded_hash`, `hash_param`, `seeded_hash_param`, and from any generic-table operation that hashes such a key. This is why the external is named `caml_hash_exn` and carries no `[@@noalloc]` (`hash.c:185–190`, `ml:663–664`).
- Polymorphic `compare` inside generic operations can raise `Invalid_argument "compare: functional value"` on functional keys (standard `Stdlib.compare` behavior; the generic ops use `compare`, see §2.4).
- `create` raises nothing: any `int` (including negative) is accepted and clamped (§2.2).

---

## 2. Behavioral semantics

### 2.1 Internal representation (reference; informs observable behavior)

```ocaml
type ('a, 'b) t = {
  mutable size: int;                        (* number of entries *)
  mutable data: ('a, 'b) bucketlist array;  (* the buckets *)
  seed: int;                                (* for randomization *)
  mutable initial_size: int;                (* initial array size *)
}
and ('a, 'b) bucketlist = Empty | Cons of { mutable key; mutable data; mutable next }
```
(`ml:26–37`). The **sign of `initial_size`** encodes "a traversal is ongoing" (`ml:39–47`): `ongoing_traversal h = Obj.size (Obj.repr h) < 4 || h.initial_size < 0` (`ml:45–47`); `flip_ongoing_traversal` negates it (`ml:49–50`). The `Obj.size < 4` checks (`ml:46, 103, 671, 791, 797`) exist solely for compatibility with old-format tables that were marshaled by pre-4.00 OCaml and unmarshaled.

### 2.2 `create` (`ml:86–93`)

```ocaml
let create ?(random = is_randomized ()) initial_size =
  let s = power_2_above 16 initial_size in
  let seed = if random then Rng.bits () else 0 in
  { initial_size = s; size = 0; seed; data = Array.make s Empty }
```
- **Clamping:** `power_2_above 16 n` (`ml:81–84`) starts at 16 and doubles while `x < n && x * 2 <= Sys.max_array_length`. Consequences: minimum bucket count is **16** (also for `n <= 0`); bucket count is always a power of two; maximum is the largest such double whose doubling would not exceed `Sys.max_array_length`. In this OxCaml runtime, 64-bit headers reserve `R = 8` bits for mixed blocks (`mlvalues.h:171–181`), so `HEADER_WOSIZE_BITS = 46` and `Sys.max_array_length = Max_wosize = 2^46 − 1` (`mlvalues.h:195–196, 325`; `sys.ml:49`); the largest reachable bucket array is therefore `2^45`.
- **`~random` omitted** (i.e. `None`): the default is `is_randomized ()` **evaluated at call time** — the current global flag. `~random:false` ⇒ `seed = 0`. `~random:true` ⇒ `seed = Rng.bits ()`, a fresh 30-bit value in `[0, 2^30)` (hence the doc's "2^{30} different hash functions", `mli:94`).
- `initial_size` field stores `s` (the clamped power of two), **not** the user's `n` — this is what `reset` returns to.

### 2.3 Randomization machinery

- `randomized_default` (`ml:54–58`): computed once at module init. Reads `Sys.getenv "OCAMLRUNPARAM"`; if that raises `Not_found`, reads `Sys.getenv "CAMLRUNPARAM"`; if that also raises, uses `""`. Then `String.contains params 'R'` — i.e. a **case-sensitive search for the character `'R'` anywhere in the string** (so e.g. `OCAMLRUNPARAM=v=0x400,R` and even a stray `R` inside another option's value both enable it). This is parsed in OCaml code, not by the C runtime.
- `randomized : bool Atomic.t` initialized to that default (`ml:60`). `randomize () = Atomic.set randomized true` (`ml:62`) — one-way, no API to unset (doc `mli:235–238`). `is_randomized () = Atomic.get randomized` (`ml:63`).
- Per-table seeds come from `Rng` (`ml:65–73`): a **domain-local** PRNG state, `Domain.Safe.DLS.new_key Random.State.make_self_init` — each domain self-initializes its own `Random.State` on first use; `bits () = Random.State.bits (Obj.magic_uncontended (Domain.Safe.DLS.get key))` returns 30 random bits. (Upstream 5.2 uses `Domain.DLS` directly; the `Domain.Safe.DLS`/`Obj.magic_uncontended` wrapper is OxCaml-specific but semantically identical.)

### 2.4 Equality and hashing used by the generic interface

- **Equality is `Stdlib.compare … = 0`, NOT `(=)`** (despite `mli:44` saying "polymorphic equality `(=)`"). `find`/`find_opt` test `compare key k = 0` with the **query first** (`ml:703, 709, 713, 717, 723, 729, 733, 737`); `remove`, `find_all`, `replace`, `mem` test `compare k key = 0` with the **stored key first** (`ml:686, 744, 753, 770`). Observable consequence: `nan` keys ARE found (`compare nan nan = 0`), unlike `(=)`.
- **Bucket selection:** `key_index h key = (seeded_hash_param 10 100 h.seed key) land (Array.length h.data - 1)` (`ml:670–673`), i.e. masking the low bits — bucket count must be a power of two.

### 2.5 Hash functions (`ml:663–668`, `hash.c`)

```ocaml
external seeded_hash_param : int -> int -> int -> 'a -> int @@ portable = "caml_hash_exn"
let hash x = seeded_hash_param 10 100 0 x
let hash_param n1 n2 x = seeded_hash_param n1 n2 0 x
let seeded_hash seed x = seeded_hash_param 10 100 seed x
```
- Argument order of the external: `count(meaningful) -> limit(total) -> seed -> value`. Defaults used by `hash`/`seeded_hash`: `meaningful = 10`, `total = 100` (`mli:555–557`).
- `caml_hash_exn` (`hash.c:192–309`): MurmurHash3-based mixing (`hash.c:29–46`; the mli's "it's SipHash" at `mli:43` is inherited from upstream and is inaccurate — the algorithm is MurmurHash3-derived). Breadth-first traversal with a queue; `total` is clamped: `if (sz < 0 || sz > 256) sz = 256` (`HASH_QUEUE_SIZE`, `hash.c:179, 203–204`); `meaningful` is not clamped (≤ 0 means only the seed is mixed). Result is folded to `[0, 2^30 − 1]`: `Val_int(h & 0x3FFFFFFFU)` (`hash.c:306–308`) — `hash` always returns a nonnegative int identical on 32/64-bit. Raises `Invalid_argument "hash: mixed block value"` on mixed blocks (`hash.c:290–292`). OxCaml renamed the primitive from `caml_hash` to `caml_hash_exn` and dropped `[@@noalloc]` precisely because it can raise (`hash.c:185–190`).
- Documented guarantee: `x = y` or `compare x y = 0` ⇒ `hash x = hash y`; terminates on cyclic structures (`mli:530–533`).

### 2.6 Multi-binding semantics (the core contract)

A key may have several simultaneous bindings; bindings of the same key live in one bucket, **most recent nearest the head**.

- **`add`** (`ml:675–680`): unconditionally **prepends** `Cons{key; data; next = old_bucket}` at the bucket head, increments `size`, then checks resize. Previous bindings for the key are *hidden, not removed* (doc `mli:125–128`).
- **`find`** (`ml:705–717`): returns the **first match in the bucket = most recent binding**; raises `Not_found` if none. (Implementation unrolls the first 3 cells then recurses — perf only.)
- **`find_opt`** (`ml:725–737`): same, `None` instead of raising.
- **`find_all`** (`ml:739–747`): returns **all** bindings for the key in bucket order, i.e. **most-recent-first** ("current binding first, then previous bindings, in reverse order of introduction", `mli:143–146`). Implementation is `[@tail_mod_cons]`.
- **`remove`** (`ml:682–697`): scans the bucket and deletes **only the first match** (the most recent binding), decrementing `size`, then **stops** (`remove_bucket` does not recurse after a hit, `ml:685–692`). The previous binding for that key, if any, is thereby restored. Silent no-op if the key is absent.
- **`replace`** (`ml:749–764`): `replace_bucket` scans for the **first** matching cell. If found: **mutates that cell in place** — `slot.key <- key; slot.data <- data` (`ml:752–754`) — so (a) the binding **keeps its position** in the bucket (it is *not* remove+re-add; iteration position is preserved), (b) **older shadowed bindings for the same key are left intact**, and (c) **the stored key is overwritten with the argument key** (observable when keys are `compare`-equal but not physically identical: subsequent `iter`/`to_seq` yields the *new* key object). If no match (`replace_bucket` returns `true`): prepends a new cell, increments `size`, and checks resize — exactly like `add` (`ml:760–763`). The doc's claim that it is "functionally equivalent to remove followed by add" (`mli:160–161`) holds only up to (unspecified) iteration order.
- **`mem`** (`ml:766–773`): true iff some binding exists.

### 2.7 Growth policy and `resize` (reference for stdlib; not to be copied)

- **Trigger** (checked in `add` and in the insert path of `replace`, *after* incrementing size): `if h.size > Array.length h.data lsl 1 then resize key_index h` (`ml:679–680, 762–763`). Precedence makes this `size > (nbuckets lsl 1)`: resize fires when the load factor strictly exceeds 2 (i.e. at `size = 2*nbuckets + 1`).
- **`resize`** (`ml:160–169`): doubles the bucket array (`nsize = osize * 2`) **only if `nsize < Sys.max_array_length` (strict)**; otherwise silently does nothing (chains keep growing). Sets `h.data` before rehashing so the index function sees the new size. `insert_all_buckets` (`ml:132–158`) appends to per-bucket tails, **preserving the relative order of bindings**, so most-recent-first order per key survives resizing. If no traversal is ongoing, cells are reused in place (`inplace`, mutating `next` pointers); during a traversal, cells are copied instead (`ml:166, 137–141`).

### 2.8 `clear` vs `reset`

- **`clear`** (`ml:95–99`): if `size > 0`, sets `size <- 0` and fills the existing `data` array with `Empty`. **Capacity is retained.** No-op when already empty. Doc: use `reset` instead to shrink (`mli:110–111`).
- **`reset`** (`ml:101–109`): sets `size <- 0` and **replaces `data` with a fresh array of length `abs h.initial_size`** — the (clamped) size from `create` time. If the current array already has that length (or the table is old-format), it just behaves as `clear`. (`abs` because the sign carries the traversal flag.) `@since 4.00`.

### 2.9 `copy` (`ml:111–128`)

`{ h with data = Array.map copy_bucketlist h.data }`: copies the **bucket spine** (fresh `Cons` cells) so subsequent structural mutations of either table don't affect the other, but **keys and values are shared** (shallow copy of contents). `seed`, `size`, and `initial_size` are copied verbatim — including, as an edge case, a negative `initial_size` if copied from inside an active traversal of the source (harmless: it only disables in-place resize in the copy).

### 2.10 `length` (`ml:130`)

`let length h = h.size` — an **O(1) stored counter** of bindings (multiple bindings per key each count; equals the number of calls `iter` makes; doc `mli:218–221`).

### 2.11 `iter` / `fold` (`ml:171–187`, `ml:222–241`)

- Traverse the bucket array from index 0 upward; within each bucket from head to tail. Combined with §2.6, **for a given key, bindings are visited most-recent-first** — this is a documented guarantee (`mli:169–171`, `mli:203–205`). Overall order is otherwise **unspecified** (`mli:168`, `mli:202`).
- Documented: non-randomized tables enumerate in an order **reproducible between runs and between minor OCaml versions**; randomized tables in arbitrary order (`mli:173–177`, `mli:207–211`).
- Documented: behavior **unspecified if the table is modified by `f` during iteration** (`mli:179–180`, `mli:213–214`).
- Both set the ongoing-traversal flag on entry and restore it on exit, **including on exception** (re-raised) (`ml:177–187`, `ml:229–241`). The flag's only effect is to make a concurrent-with-iteration `resize` copy cells instead of mutating them in place, so iteration continues over a coherent (old) structure after a mid-iteration `add` triggers growth.
- `fold f tbl init` computes `f kN dN (... (f k1 d1 init)...)` — accumulator threaded through each visited binding (`mli:196–199`).

### 2.12 `filter_map_inplace` (`ml:189–220`)

For every binding (each cons cell, in iteration order — so for duplicated keys, **each binding is presented separately**, most-recent-first within its bucket): apply `f key data`.
- `None` ⇒ the binding is unlinked and `size` decremented (`ml:197–199`).
- `Some new_data` ⇒ **`c.data <- new_data` mutated in place** (`ml:200–206`): the cell keeps its position; **the key is not rewritten** (unlike `replace`).
Sets/restores the traversal flag with exception safety like `iter` (`ml:211–220`). "Other comments for `iter` apply as well" (`mli:191`). `@since 4.03`.

### 2.13 `stats` (`ml:254–266`)

Computed by full traversal (not cached): `num_bindings = h.size`; `num_buckets = Array.length h.data`; `max_bucket_length` = max chain length; `bucket_histogram` = array of length `mbl + 1` counting buckets per chain length (empty buckets count in `histo.(0)`).

### 2.14 Sequences

- **`to_seq`** (`ml:270–283`): **captures `tbl.data` (the array) eagerly at the time `to_seq` is called**; the traversal itself is lazy. It is **not a snapshot**: bucket cells are read at force time, so mutations made between forces are (partially) visible; the captured array means a resize after capture decouples the sequence from the table (and an in-place resize mutates the very cells being traversed). Hence the doc-level contract is only: unspecified order; same-key bindings appear **most-recent-first**; **behavior unspecified if the table is modified during iteration** (`mli:288–294`). Pairs are constructed at force time; re-forcing a node re-reads the mutable cells. `@since 4.07`.
- **`to_seq_keys m = Seq.map fst (to_seq m)`**, **`to_seq_values m = Seq.map snd (to_seq m)`** — literally (`ml:285–287`; doc says the same, `mli:299, 303`).
- **`add_seq tbl s = Seq.iter (fun (k,v) -> add tbl k v) s`** (`ml:775–776`) — uses **`add`** (stacking duplicates), in sequence order.
- **`replace_seq tbl s = Seq.iter (fun (k,v) -> replace tbl k v) s`** (`ml:778–779`) — uses **`replace`**.
- **`of_seq s`** (`ml:781–784`): `let tbl = create 16 in replace_seq tbl s; tbl` — uses **`replace`** (doc: "using replace_seq … only the latest one will appear", `mli:315–318`). Note the generic `of_seq` calls `create` with `?random` defaulted, so the resulting table **is randomized iff the global default is on at call time**.

### 2.15 `rebuild` (`ml:786–800`)

Signature: `?random:bool -> ('a, 'b) t -> ('a, 'b) t`, default `random = is_randomized ()`. This 5.2-era signature has **no `old_hash` parameter** — there is no "old hash" mechanism; `rebuild` simply **re-hashes every (key, value) with the current polymorphic hash and a (possibly new) seed**:
- new capacity `s = power_2_above 16 (Array.length h.data)` (`ml:787`) — for modern tables this is just the old capacity (already a power of two ≥ 16);
- new seed: `Rng.bits ()` if `random`; else the old table's `seed` (modern format), else 0 for old-format tables (`ml:788–792`) — so a randomized input stays randomized when `~random:false`;
- `size` copied; `initial_size` copied from the source (or `s` for old-format) (`ml:793–798`);
- entries inserted via `insert_all_buckets (key_index h') false …` (`ml:799`) — **`inplace = false`, so the input table is left fully intact**, and relative order of entries within each source bucket is preserved into destination buckets. Uses the **generic** `key_index` (polymorphic `seeded_hash_param 10 100 seed`), which is why `rebuild` lives only in the generic interface. Purpose per docs: re-importing tables unmarshaled from older `Hashtbl` versions (`mli:249–262`). `@since 4.12`.

### 2.16 `MakeSeeded` functor (`ml:361–493`)

Returns `SeededS with type key = H.t`; the table type is an alias of the generic `(key, 'a) t` internally (`ml:364–365`), but is abstract (`type !'a t`) externally.
- `create = create` (the generic one, `ml:366`) — so **`?random` defaults to the current `is_randomized ()`**, and `~random:true` draws a fresh 30-bit seed; per-key indexing is `(H.seeded_hash h.seed key) land (Array.length h.data - 1)` (`ml:371–372`).
- `clear/reset/copy/iter/filter_map_inplace/fold/length/stats/to_seq*` are literally the generic functions (`ml:367–369, 485–492`).
- `add/remove/find/find_opt/find_all/replace/mem/add_seq/replace_seq` mirror the generic ones with `H.equal` in place of `compare … = 0` (`ml:374–478`). **Equality argument order** (relevant for exact replication with non-symmetric `equal`): `find`/`find_opt` call `H.equal key k` (query first, `ml:402, 408, 412, 416, 422, 428, 432, 436`); `remove`, `find_all`, `replace`, `mem` call `H.equal k key` (stored first, `ml:385, 443, 452, 469`).
- `of_seq i = let tbl = create 16 in replace_seq tbl i; tbl` (`ml:480–483`) — like the generic one, **inherits the global randomization default**.
- Functor body carries `[@@inline available]` (`ml:493`).

### 2.17 `Make` functor (`ml:495–507`)

```ocaml
module Make(H: HashedType): (S with type key = H.t) = struct
  include MakeSeeded(struct
      type t = H.t
      let equal = H.equal
      let seeded_hash (_seed: int) x = H.hash x
    end)
  let create sz = create ~random:false sz
  let of_seq i = let tbl = create 16 in replace_seq tbl i; tbl
end [@@inline available]
```
- The seed is **ignored entirely** — `H.hash` is unseeded (`ml:500`).
- `create` is shadowed to **always pass `~random:false`** (`ml:502`): seed is 0, the PRNG is never consulted, and global `randomize ()` / `OCAMLRUNPARAM=R` have **no effect** on `Make` tables (doc `mli:432–434`). `S.create` accordingly has no `?random` parameter.
- `of_seq` is re-defined over the shadowed `create`, so `Make(_).of_seq` is also always non-randomized (`ml:503–506`).

### 2.18 `MakePortable` / `MakeSeededPortable` (`ml:509–657`) — OxCaml only

`MakeSeededPortable` is a verbatim duplicate of `MakeSeeded`'s body (it cannot reuse the non-portable functor); `MakePortable` wraps it exactly as `Make` wraps `MakeSeeded` (including the `~random:false` `create` and re-defined `of_seq`, `ml:652–656`). Behavior is identical to `MakeSeeded`/`Make`; the only difference is the `@@ portable` signature requirement on `H` and on the result (`ml:509–510, 644–645`; `mli:436–439, 521–524`). Both carry `[@@inline available]` (`ml:642, 657`).

---

## 3. Version- and OxCaml-specific items

### 3.1 `@since` / `@before` inventory (must be reproduced in docs)

`@before 4.00` — `create`'s `~random` (`mli:106–107`). `@since 4.00` — `reset`, `randomize`, `statistics`, `stats`, `S.reset`, `S.stats`, `SeededHashedType`, `SeededS`, `MakeSeeded`, `seeded_hash`, `seeded_hash_param`. `@since 4.03` — `is_randomized`, `filter_map_inplace` (toplevel and in `S`/`SeededS`). `@since 4.05` — `find_opt` (everywhere). `@since 4.07` — all six seq functions (everywhere). `@since 4.12` — `rebuild`.

### 3.2 OxCaml deltas vs upstream OCaml 5.2 (verified by diff against `ocaml/ocaml@5.2`)

**In the mli** (everything else is byte-for-byte upstream 5.2, including the `[@@@warning "-53"]`-fenced `unsynchronized_access` alert):
1. Line directive `# 2 "hashtbl.mli"` at line 1.
2. `@@ portable` module modality + `open! Stdlib` (`mli:17, 19`).
3. Kind annotation on the table type: `type (!'a, !'b) t : mutable_data with 'a with 'b` (`mli:67`) vs upstream `type (!'a, !'b) t`.
4. New functors `MakePortable` (`mli:436–439`) and `MakeSeededPortable` (`mli:521–524`).
5. Doc xref `{!Stdlib.Hashtbl.seeded_hash}` instead of `{!Hashtbl.seeded_hash}` (`mli:454`).

**In the ml** (semantics-neutral except as noted):
1. `open! Stdlib`, `[@@@ocaml.flambda_o3]` (`ml:17–19`).
2. `Rng` module over `Domain.Safe.DLS` + `Obj.magic_uncontended` (`ml:65–73`) replacing upstream's bare `Domain.DLS` `prng_key` — same observable behavior (per-domain self-initialized `Random.State`, 30-bit draws).
3. `external seeded_hash_param … @@ portable = "caml_hash_exn"` with **no `[@@noalloc]`** (`ml:663–664`) vs upstream `= "caml_hash" [@@noalloc]`. The C primitive is renamed because it can raise (mixed blocks) (`hash.c:185–190`); behavioral delta vs upstream: `Invalid_argument "hash: mixed block value"` on OxCaml mixed-block values (`hash.c:290–292`).
4. `[@@inline available]` on all four functor bodies (`ml:493, 507, 642, 657`).
5. The duplicated `MakeSeededPortable`/`MakePortable` implementations (`ml:509–657`).
6. Runtime constant difference: OxCaml fixes `HEADER_RESERVED_BITS = 8` (`mlvalues.h:178–181`), so `Sys.max_array_length = 2^46 − 1` on 64-bit (upstream default is `2^54 − 1`); this bounds `power_2_above` and `resize` (§2.2, §2.7).

### 3.3 Practical notes for the reimplementation team

- The doc-level contract a replacement must honor: per-key most-recent-first multi-binding semantics (§2.6), `length` O(1), `clear`/`reset` capacity behavior, randomization machinery (§2.3) including `Make` ignoring it, `of_seq`/`replace_seq` using `replace` vs `add_seq` using `add`, `Not_found` only from `find`, sequence laziness contract, and the documented reproducible enumeration order for non-randomized tables across runs (`mli:173–177`) — note a Swiss table cannot reproduce stdlib's *exact* bucket order, only an order that is itself deterministic across runs; whether bit-exact order parity with the current stdlib is required must be decided explicitly.
- Generic-interface equality is `compare … = 0` (nan-friendly), not `(=)` — differential tests against stdlib will catch this with `nan` keys.
- `replace` must update the stored key object, preserve binding position, and leave shadowed duplicates intact; `filter_map_inplace` must update values only and visit every duplicate binding.
- Mid-iteration mutation is officially unspecified, but stdlib is exception-safe about its internal traversal flag; matching the "unspecified" contract is sufficient.

## Open questions (from researcher)
- Must the reimplementation reproduce stdlib's exact enumeration order for non-randomized tables (bit-for-bit iter/fold/to_seq order), or only the documented guarantees (per-key most-recent-first + deterministic across runs)? A Swiss table cannot match stdlib's bucket-list order exactly.
- Must the reimplementation support unmarshaling of tables marshaled by stdlib Hashtbl (same record layout: size/data/seed/initial_size and bucketlist), and the Obj.size<4 old-format compatibility paths (Invalid_argument "Hashtbl: unsupported hash table format", rebuild's old-format handling)? If yes, the in-memory representation is constrained far beyond the mli.
- Does the kind annotation `type (!'a,!'b) t : mutable_data with 'a with 'b` need to hold of the new representation (it will if the table is ordinary mutable OCaml data parameterized only by 'a/'b), and must MakePortable/MakeSeededPortable avoid sharing code with the non-portable functors as stdlib does, or is any portable-checked implementation acceptable?
- Is matching `replace`'s in-place key overwrite (slot.key <- key) required observable behavior (it is observable via iter/to_seq when keys are compare-equal but physically distinct)? Assumed yes in the spec.
- The per-table seed source (per-domain Random.State.make_self_init, 30-bit draws) — must the reimplementation share the same DLS PRNG stream as stdlib (affects programs mixing both implementations and expecting identical seed sequences), or is an independent PRNG acceptable?

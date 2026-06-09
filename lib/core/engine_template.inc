(* The Swiss-table engine body. NOT compiled directly: dune rules
   prepend a per-instantiation prelude defining [module G] (the group
   probing implementation) and [open! Swiss_core.Core_impl] (shared
   state + helpers), producing the swiss / swiss_neon modules. This
   textual instantiation guarantees full specialization: a functor
   application of this size is not reliably inlined by flambda2, which
   leaves G.probe_* as indirect calls in the hot loops. *)

module _ : Swiss_core.Core_impl.GROUP = G

(* Re-exported shared API (the mutable state is global and shared
   across instantiations, like stdlib's). *)
external seeded_hash_param : int -> int -> int -> 'a -> int @@ portable
  = "caml_hash_exn"

let hash x = seeded_hash_param 10 100 0 x
let hash_param n1 n2 x = seeded_hash_param n1 n2 0 x
let seeded_hash seed x = seeded_hash_param 10 100 seed x
let randomize = randomize
let is_randomized = is_randomized

(* ------------------------------------------------------------------ *)
(* Representation (design §2)                                          *)
(* ------------------------------------------------------------------ *)

type ('a, 'b) core = {
  ctrl : Bytes.t; (* length buckets + 8; tail mirrors ctrl[0..7] *)
  keys : Obj.t array; (* length buckets; dummy in non-FULL slots *)
  vals : Obj.t array; (* length buckets; dummy in non-FULL slots *)
  mask : int; (* buckets - 1; buckets is a power of two >= 8 *)
}

type ('a, 'b) t : mutable_data with 'a with 'b = {
  mutable c : ('a, 'b) core; (* swapped wholesale on resize/reset *)
  mutable items : int; (* number of FULL slots = distinct live keys *)
  mutable growth_left : int; (* inserts into EMPTY slots still allowed *)
  mutable shadow : ('a, 'b) shadow; (* older bindings of duplicated keys *)
  mutable nshadow : int; (* total shadowed bindings *)
  seed : int;
  mutable initial_buckets : int; (* clamped size from create; reset target *)
}
[@@unsafe_allow_any_mode_crossing
  (* The Obj.t slots only ever hold 'a keys, 'b values, ('a * 'b) list
     stacks, or the immediate () dummy, so the representation genuinely
     supports [mutable_data with 'a with 'b]. Same idiom as stdlib's
     domain.ml. *)]

and ('a, 'b) shadow = ('a, ('a * 'b) list) t option

type statistics = {
  num_bindings : int;
  num_buckets : int;
  max_bucket_length : int;
  bucket_histogram : int array;
}

(* The dummy is the unit immediate. Obj.t's bare kind crosses no modes,
   so a toplevel [dummy : Obj.t] would contaminate every closure using
   it; as a function it is created (for free) at each use site. *)
let[@inline] dummy () : Obj.t = Obj.repr ()

(* The engine works on a uniform untyped instance; the casts below are
   representation-identical (every slot is Obj.t in any instance). *)
type repr = (Obj.t, Obj.t) t

let[@inline] repr (t : ('a, 'b) t) : repr = Obj.magic t
let[@inline] of_repr (t : repr) : ('a, 'b) t = Obj.magic t
let[@inline] get_shadow (t : repr) : repr option = Obj.magic t.shadow
let[@inline] set_shadow (t : repr) (s : repr option) =
  t.shadow <- (Obj.magic s : (Obj.t, (Obj.t * Obj.t) list) t option)

type stack = (Obj.t * Obj.t) list

let[@inline] stack_of (v : Obj.t) : stack = Obj.obj v

(* ------------------------------------------------------------------ *)
(* Sizing (design §8: clamp, never raise)                              *)
(* ------------------------------------------------------------------ *)

let max_buckets =
  let rec go b = if b <= Sys.max_array_length / 2 then go (b * 2) else b in
  go 8

let[@inline] capacity_of_buckets b = b / 8 * 7

let next_pow2 n =
  let n = n - 1 in
  let n = n lor (n lsr 1) in
  let n = n lor (n lsr 2) in
  let n = n lor (n lsr 4) in
  let n = n lor (n lsr 8) in
  let n = n lor (n lsr 16) in
  let n = n lor (n lsr 32) in
  n + 1

let buckets_for_capacity cap =
  if cap <= capacity_of_buckets G.width then G.width
  else if cap >= capacity_of_buckets max_buckets then max_buckets
  else next_pow2 (cap * 8 / 7)

let make_core buckets : ('a, 'b) core =
  {
    ctrl = Bytes.make (buckets + G.width) ctrl_empty;
    keys = Array.make buckets (dummy ());
    vals = Array.make buckets (dummy ());
    mask = buckets - 1;
  }

let make_table ~seed buckets : repr =
  {
    c = make_core buckets;
    items = 0;
    growth_left = capacity_of_buckets buckets;
    shadow = None;
    nshadow = 0;
    seed;
    initial_buckets = buckets;
  }

(* ------------------------------------------------------------------ *)
(* Core helpers shared by the engine and the hash-free operations      *)
(* ------------------------------------------------------------------ *)

let[@inline] h2_of_hash h = (h lsr 23) land 0x7f

(* Write a ctrl byte and its mirror (branchless; for i >= 8 the second
   write is idempotent, for i < 8 it lands at buckets + i). *)
let[@inline] set_ctrl (c : ('a, 'b) core) i ch =
  Bytes.unsafe_set c.ctrl i ch;
  Bytes.unsafe_set c.ctrl (((i - G.width) land c.mask) + G.width) ch

let probe_invariant_failure () =
  raise (Invalid_argument "Swiss: probe invariant violated")

(* First empty-or-deleted slot for hash [h] in core [c]. Used on fresh
   cores during rehash (no eq calls; key known absent). *)
let find_insert_fresh (c : ('a, 'b) core) h =
  let mask = c.mask in
  let rec loop pos stride =
    let me = G.match_empty_or_deleted c.ctrl pos in
    if me <> 0 then (pos + G.lowest_idx me) land mask
    else begin
      let stride = stride + G.width in
      if stride > mask + 1 then probe_invariant_failure ();
      loop ((pos + stride) land mask) stride
    end
  in
  loop (h land mask) 0

(* Erase the FULL slot [idx] of [c]: EMPTY-vs-DELETED group rule
   (ALG §6), ctrl flipped before the slots are dummied (design §2
   publish ordering), counters committed only if [c] is still live. *)
let erase (t : repr) (c : (Obj.t, Obj.t) core) idx =
  (* Pre-state gate: under reentrant misuse a nested operation may have
     already erased this slot; a second erase must be a no-op or the
     counters double-commit (verified bounded but incoherent without
     this check). Makes per-slot erase idempotent. *)
  if is_full_byte (Bytes.unsafe_get c.ctrl idx) then begin
    let mask = c.mask in
    let before = (idx - G.width) land mask in
    let eb = G.match_empty c.ctrl before in
    let ea = G.match_empty c.ctrl idx in
    let to_deleted =
      G.leading_zero_count eb + G.trailing_zero_count ea >= G.width
    in
    set_ctrl c idx (if to_deleted then ctrl_deleted else ctrl_empty);
    Array.unsafe_set c.keys idx (dummy ());
    Array.unsafe_set c.vals idx (dummy ());
    if t.c == c then begin
      t.items <- t.items - 1;
      if not to_deleted then t.growth_left <- t.growth_left + 1
    end
  end

(* ------------------------------------------------------------------ *)
(* The engine: every operation that needs equality / hashing           *)
(* ------------------------------------------------------------------ *)

module type EQH = sig @@ portable
  (* find/find_opt call [eq_find query stored];
     add/replace/remove/mem/find_all call [eq_upd stored query]
     (stdlib's argument orders, API §2.4/§2.16; add pinned stored-first). *)
  val eq_find : Obj.t -> Obj.t -> bool
  val eq_upd : Obj.t -> Obj.t -> bool

  (* seed -> key -> nonnegative 30-bit hash *)
  val hash : int -> Obj.t -> int

  (* True iff [hash] runs no user code and re-hashing a key that was
     already hashed at insertion cannot raise (i.e. the deterministic
     polymorphic hash). Enables the in-place tombstone purge; functor
     instantiations must say false so the copying purge preserves
     exception-atomicity under raising/reentrant user hashes. *)
  val pure_hash : bool
end

module Engine (E : EQH) = struct
  (* All probe walks take the core snapshot explicitly: callers read
     [t.c] exactly once and never re-read it after user code (design §2
     snapshot discipline). *)

  (* The probe walks below are deliberately written as flat while-loops
     over local int refs (which flambda2 demotes to registers/stack):
     `let rec` inner loops here survive closure conversion as per-call
     heap closures, and an int64 group word live across an eq call gets
     boxed. The int64 [g] is dead before any eq call — every needed
     mask is derived as a native int right after the load. Verified
     allocation-free with bench/allocprobe.ml (0.00 minor words/op). *)

  let find_idx_query (c : (Obj.t, Obj.t) core) key h =
    let ctrl = c.ctrl and keys = c.keys and mask = c.mask in
    let tag = h2_of_hash h in
    let pos = ref (h land mask) in
    let stride = ref 0 in
    let result = ref (-2) in
    while !result = -2 do
      let p = !pos in
      let #(m0, e0) = G.probe_find ctrl p tag in
      let m = ref m0 in
      let has_empty = e0 <> 0 in
      while !result = -2 && !m <> 0 do
        let idx = (p + G.lowest_idx !m) land mask in
        if E.eq_find key (Array.unsafe_get keys idx) then result := idx
        else m := G.clear_lowest !m
      done;
      if !result = -2 then
        if has_empty then result := -1
        else begin
          stride := !stride + G.width;
          if !stride > mask + 1 then probe_invariant_failure ();
          pos := (p + !stride) land mask
        end
    done;
    !result

  let find_idx_upd (c : (Obj.t, Obj.t) core) key h =
    let ctrl = c.ctrl and keys = c.keys and mask = c.mask in
    let tag = h2_of_hash h in
    let pos = ref (h land mask) in
    let stride = ref 0 in
    let result = ref (-2) in
    while !result = -2 do
      let p = !pos in
      let #(m0, e0) = G.probe_find ctrl p tag in
      let m = ref m0 in
      let has_empty = e0 <> 0 in
      while !result = -2 && !m <> 0 do
        let idx = (p + G.lowest_idx !m) land mask in
        if E.eq_upd (Array.unsafe_get keys idx) key then result := idx
        else m := G.clear_lowest !m
      done;
      if !result = -2 then
        if has_empty then result := -1
        else begin
          stride := !stride + G.width;
          if !stride > mask + 1 then probe_invariant_failure ();
          pos := (p + !stride) land mask
        end
    done;
    !result

  (* One walk deciding present/absent: result >= 0 is the existing
     slot; otherwise [lnot result] is the first empty-or-deleted slot
     seen along the probe (the insert position). The walk stops only at
     a group containing EMPTY (ALG §6: a full/deleted-only group does
     not prove absence). *)
  let upsert_idx (c : (Obj.t, Obj.t) core) key h =
    let ctrl = c.ctrl and keys = c.keys and mask = c.mask in
    let tag = h2_of_hash h in
    let pos = ref (h land mask) in
    let stride = ref 0 in
    let insert = ref (-1) in
    (* Sentinel must be outside the result range: found idx is >= 0 and
       absent is [lnot insert] in [-(mask+2), -1] — so -2 would collide
       with an insert slot of 1. min_int is unreachable. *)
    let result = ref min_int in
    while !result = min_int do
      let p = !pos in
      let #(m0, e0, med) = G.probe_insert ctrl p tag in
      let m = ref m0 in
      let has_empty = e0 <> 0 in
      while !result = min_int && !m <> 0 do
        let idx = (p + G.lowest_idx !m) land mask in
        if E.eq_upd (Array.unsafe_get keys idx) key then result := idx
        else m := G.clear_lowest !m
      done;
      if !result = min_int then begin
        if !insert < 0 && med <> 0 then
          insert := (p + G.lowest_idx med) land mask;
        if has_empty then result := lnot !insert
          (* insert >= 0 is guaranteed: this group has an EMPTY byte,
             which is also empty-or-deleted *)
        else begin
          stride := !stride + G.width;
          if !stride > mask + 1 then probe_invariant_failure ();
          pos := (p + !stride) land mask
        end
      end
    done;
    !result

  (* True in-place tombstone purge (ALG §8 / hashbrown rehash_in_place).
     Only used when [E.pure_hash]: the purge re-hashes stored keys with
     the live core in a torn state, so the hash must run no user code
     and must not raise — both hold for the deterministic generic hash
     applied to keys it already hashed at insertion. With no user-code
     call inside, there is no observation point mid-purge; the publish
     ordering (FULL implies real entry) is maintained throughout, so
     even the documented-UB unsynchronized reader stays memory-safe. *)
  let rehash_in_place (t : repr) =
    prerr_string "P";
    let c = t.c in
    let ctrl = c.ctrl and keys = c.keys and vals = c.vals and mask = c.mask in
    let buckets = mask + 1 in
    (* Phase 1: FULL -> DELETED (live entry awaiting placement);
       EMPTY/DELETED -> EMPTY. Bytewise: the purge is O(n) in hash
       calls anyway, group-width-at-a-time conversion is not worth a
       GROUP extension. Then repair the mirrored tail. *)
    for i = 0 to buckets - 1 do
      Bytes.unsafe_set ctrl i
        (if is_full_byte (Bytes.unsafe_get ctrl i) then ctrl_deleted
         else ctrl_empty)
    done;
    Bytes.blit ctrl 0 ctrl buckets G.width;
    (* Phase 2: place every DELETED-marked live entry. Each iteration
       of the inner loop either finishes slot [i] (same-window or
       move-to-EMPTY) or swaps with another not-yet-placed entry whose
       own slot [new_i] becomes FULL — strictly decreasing the number
       of unplaced entries, hence termination. *)
    for i = 0 to buckets - 1 do
      while Bytes.unsafe_get ctrl i = ctrl_deleted do
        let h = E.hash t.seed (Array.unsafe_get keys i) in
        let start = h land mask in
        let new_i = find_insert_fresh c h in
        if
          ((i - start) land mask) / G.width
          = ((new_i - start) land mask) / G.width
        then
          (* Already reachable from its own probe window: keep it. *)
          set_ctrl c i (Char.unsafe_chr (h2_of_hash h))
        else if Bytes.unsafe_get ctrl new_i = ctrl_empty then begin
          (* Move: slots written before the FULL ctrl byte; the source
             flips non-FULL before being dummied (publish ordering). *)
          Array.unsafe_set keys new_i (Array.unsafe_get keys i);
          Array.unsafe_set vals new_i (Array.unsafe_get vals i);
          set_ctrl c new_i (Char.unsafe_chr (h2_of_hash h));
          set_ctrl c i ctrl_empty;
          Array.unsafe_set keys i (dummy ());
          Array.unsafe_set vals i (dummy ())
        end
        else begin
          (* Target holds another unplaced entry: swap, mark the
             target FULL (it now holds OUR entry, written first), and
             keep placing the displaced entry at [i]. *)
          prerr_string "S";
          let k = Array.unsafe_get keys new_i in
          let v = Array.unsafe_get vals new_i in
          Array.unsafe_set keys new_i (Array.unsafe_get keys i);
          Array.unsafe_set vals new_i (Array.unsafe_get vals i);
          set_ctrl c new_i (Char.unsafe_chr (h2_of_hash h));
          Array.unsafe_set keys i k;
          Array.unsafe_set vals i v
        end
      done
    done;
    t.growth_left <- capacity_of_buckets buckets - t.items

  (* Same-size tombstone purge or growth. Purges happen in place for
     pure-hash instantiations (zero allocation, no transient copy);
     otherwise — and for growth — a fresh core is fully built before
     the single commit (a raising user hash leaves [t] untouched). *)
  let reserve_grow (t : repr) =
    let c = t.c in
    let buckets = c.mask + 1 in
    let full_cap = capacity_of_buckets buckets in
    if E.pure_hash && t.items + 1 <= full_cap / 2 then rehash_in_place t
    else begin
    let nb =
      if t.items + 1 <= full_cap / 2 then buckets
      else buckets_for_capacity (max (t.items + 1) (full_cap + 1))
    in
    (* The hard wall (design §8): at max_buckets with no headroom there
       is nothing to grow into — raise rather than let growth_left go
       negative and degrade to a full rebuild per insert. Unreachable
       below ~7*2^42 live entries. *)
    if capacity_of_buckets nb <= t.items then raise Out_of_memory;
    let nc : (Obj.t, Obj.t) core = make_core nb in
    for i = 0 to c.mask do
      if is_full_byte (Bytes.unsafe_get c.ctrl i) then begin
        let k = Array.unsafe_get c.keys i in
        let h = E.hash t.seed k in
        let idx = find_insert_fresh nc h in
        Array.unsafe_set nc.keys idx k;
        Array.unsafe_set nc.vals idx (Array.unsafe_get c.vals i);
        set_ctrl nc idx (Char.unsafe_chr (h2_of_hash h))
      end
    done;
    t.growth_left <- capacity_of_buckets nb - t.items;
    t.c <- nc
    end
  (* The retired core [c] is never written again: live iterators may
     still hold it (design §2). *)

  (* Publish a new binding at [idx] of snapshot [c]: slots before ctrl.
     Pre-state gate: by construction [idx] is empty-or-deleted, except
     under reentrant misuse where a nested operation filled it first —
     then overwrite the slot but leave the counters alone (the FULL
     count is unchanged), keeping the accounting coherent. *)
  let do_insert (t : repr) (c : (Obj.t, Obj.t) core) idx key v h =
    let pre = Bytes.unsafe_get c.ctrl idx in
    Array.unsafe_set c.keys idx key;
    Array.unsafe_set c.vals idx v;
    set_ctrl c idx (Char.unsafe_chr (h2_of_hash h));
    if (not (is_full_byte pre)) && t.c == c then begin
      t.items <- t.items + 1;
      if pre = ctrl_empty then t.growth_left <- t.growth_left - 1
    end

  (* Insert of a key known absent from snapshot [c] (design §3 policy:
     probe-first, reserve only when an EMPTY slot must be consumed at
     growth_left = 0). *)
  let insert_absent (t : repr) (c : (Obj.t, Obj.t) core) idx key v h =
    if Bytes.unsafe_get c.ctrl idx <> ctrl_empty || t.growth_left > 0 then
      do_insert t c idx key v h
    else begin
      reserve_grow t;
      let c = t.c in
      do_insert t c (find_insert_fresh c h) key v h
    end

  (* --- shadow-table plumbing (design §3) --- *)

  let shadow_table (t : repr) : repr =
    match get_shadow t with
    | Some s -> s
    | None ->
      let s = make_table ~seed:t.seed 16 in
      set_shadow t (Some s);
      s

  (* Push one shadowed binding onto [key]'s stack. [h] is valid for the
     shadow table too (same seed). *)
  let shadow_push (t : repr) key (entry : Obj.t * Obj.t) h =
    let s = shadow_table t in
    let cs = s.c in
    let r = upsert_idx cs key h in
    if r >= 0 then
      Array.unsafe_set cs.vals r
        (Obj.repr (entry :: stack_of (Array.unsafe_get cs.vals r)))
    else insert_absent s cs (lnot r) key (Obj.repr [ entry ]) h

  (* Pop the top of [key]'s stack into slot [idx] of [c]; returns false
     if there is nothing to pop. Deletes emptied stack entries (stacks
     are never empty, design §3). *)
  let shadow_pop_into (t : repr) (c : (Obj.t, Obj.t) core) idx key h =
    if t.nshadow <= 0 then false
    else
      match get_shadow t with
      | None -> false
      | Some s ->
        let cs = s.c in
        let rs = find_idx_upd cs key h in
        if rs < 0 then false
        else begin
          match stack_of (Array.unsafe_get cs.vals rs) with
          | [] ->
            (* unreachable by invariant; clean up defensively *)
            erase s cs rs;
            false
          | (k1, v1) :: rest ->
            Array.unsafe_set c.keys idx k1;
            Array.unsafe_set c.vals idx v1;
            (if rest = [] then erase s cs rs
             else Array.unsafe_set cs.vals rs (Obj.repr rest));
            if t.c == c then begin
              t.nshadow <- t.nshadow - 1;
              if t.nshadow = 0 then set_shadow t None
            end;
            true
        end

  (* --- public-facing operations (untyped) --- *)

  let add (t : repr) key v =
    let h = E.hash t.seed key in
    let c = t.c in
    let r = upsert_idx c key h in
    if r >= 0 then begin
      let k0 = Array.unsafe_get c.keys r and v0 = Array.unsafe_get c.vals r in
      shadow_push t key (k0, v0) h;
      (* the new key object becomes current, like stdlib's fresh Cons *)
      Array.unsafe_set c.keys r key;
      Array.unsafe_set c.vals r v;
      if t.c == c then t.nshadow <- t.nshadow + 1
    end
    else insert_absent t c (lnot r) key v h

  let replace (t : repr) key v =
    let h = E.hash t.seed key in
    let c = t.c in
    let r = upsert_idx c key h in
    if r >= 0 then begin
      (* in place: position kept, key object overwritten, shadowed
         duplicates untouched (API §2.6) *)
      Array.unsafe_set c.keys r key;
      Array.unsafe_set c.vals r v
    end
    else insert_absent t c (lnot r) key v h

  let remove (t : repr) key =
    let h = E.hash t.seed key in
    let c = t.c in
    let r = find_idx_upd c key h in
    if r >= 0 then
      if not (shadow_pop_into t c r key h) then erase t c r

  let find (t : repr) key =
    let c = t.c in
    let r = find_idx_query c key (E.hash t.seed key) in
    if r >= 0 then Array.unsafe_get c.vals r else raise Not_found

  let find_opt (t : repr) key =
    let c = t.c in
    let r = find_idx_query c key (E.hash t.seed key) in
    if r >= 0 then Some (Array.unsafe_get c.vals r) else None

  let mem (t : repr) key =
    find_idx_upd t.c key (E.hash t.seed key) >= 0

  let find_all (t : repr) key : Obj.t list =
    let h = E.hash t.seed key in
    let c = t.c in
    let r = find_idx_upd c key h in
    if r < 0 then []
    else begin
      let v0 = Array.unsafe_get c.vals r in
      let rest =
        if t.nshadow <= 0 then []
        else
          match get_shadow t with
          | None -> []
          | Some s ->
            let cs = s.c in
            let rs = find_idx_upd cs key h in
            if rs < 0 then []
            else List.map snd (stack_of (Array.unsafe_get cs.vals rs))
      in
      v0 :: rest
    end

  let filter_map_inplace (f : Obj.t -> Obj.t -> Obj.t option) (t : repr) =
    let c = t.c in
    for i = 0 to c.mask do
      if is_full_byte (Bytes.unsafe_get c.ctrl i) then begin
        (* Present the slot binding; on None pop the next-most-recent
           binding into the slot and present it too (each binding is
           shown exactly once, most-recent-first, API §2.12). *)
        let rec slot_loop () =
          let k = Array.unsafe_get c.keys i in
          let v = Array.unsafe_get c.vals i in
          match f k v with
          | Some v' ->
            Array.unsafe_set c.vals i v';
            true
          | None ->
            let h = E.hash t.seed k in
            if shadow_pop_into t c i k h then slot_loop ()
            else begin
              erase t c i;
              false
            end
        in
        if slot_loop () then begin
          (* Filter the surviving slot's remaining stack, in order. *)
          if t.nshadow > 0 then begin
            match get_shadow t with
            | None -> ()
            | Some s ->
              let k = Array.unsafe_get c.keys i in
              let h = E.hash t.seed k in
              let cs = s.c in
              let rs = find_idx_upd cs k h in
              if rs >= 0 then begin
                let dropped = ref 0 in
                let kept =
                  List.filter_map
                    (fun (k0, v0) ->
                      match f k0 v0 with
                      | Some v' -> Some (k0, v')
                      | None ->
                        incr dropped;
                        None)
                    (stack_of (Array.unsafe_get cs.vals rs))
                in
                (if kept = [] then erase s cs rs
                 else Array.unsafe_set cs.vals rs (Obj.repr kept));
                if t.c == c then begin
                  t.nshadow <- t.nshadow - !dropped;
                  if t.nshadow = 0 then set_shadow t None
                end
              end
          end
        end
      end
    done
end
[@@inline always]

(* ------------------------------------------------------------------ *)
(* Hash-free operations on the untyped representation                  *)
(* ------------------------------------------------------------------ *)

let length_repr (t : repr) = t.items + t.nshadow

(* Two-phase traversal (design §3): flat slots first (most recent
   binding of each key), then the shadow stacks (older bindings,
   newest-first within each stack). Per-key most-recent-first holds;
   no hash or equality function is ever called. *)
let iter_repr (f : Obj.t -> Obj.t -> unit) (t : repr) =
  let c = t.c in
  for i = 0 to c.mask do
    if is_full_byte (Bytes.unsafe_get c.ctrl i) then
      f (Array.unsafe_get c.keys i) (Array.unsafe_get c.vals i)
  done;
  match get_shadow t with
  | None -> ()
  | Some s ->
    let cs = s.c in
    for i = 0 to cs.mask do
      if is_full_byte (Bytes.unsafe_get cs.ctrl i) then
        List.iter
          (fun (k, v) -> f k v)
          (stack_of (Array.unsafe_get cs.vals i))
    done

let fold_repr (f : Obj.t -> Obj.t -> 'acc -> 'acc) (t : repr) (init : 'acc) =
  let acc = ref init in
  let c = t.c in
  for i = 0 to c.mask do
    if is_full_byte (Bytes.unsafe_get c.ctrl i) then
      acc := f (Array.unsafe_get c.keys i) (Array.unsafe_get c.vals i) !acc
  done;
  (match get_shadow t with
  | None -> ()
  | Some s ->
    let cs = s.c in
    for i = 0 to cs.mask do
      if is_full_byte (Bytes.unsafe_get cs.ctrl i) then
        List.iter
          (fun (k, v) -> acc := f k v !acc)
          (stack_of (Array.unsafe_get cs.vals i))
    done);
  !acc

let clear_repr (t : repr) =
  let c = t.c in
  let cap = capacity_of_buckets (c.mask + 1) in
  (* Shortcut only when truly pristine: no FULL slots, no tombstones,
     no shadow (a table that is merely empty may carry tombstones). *)
  if t.growth_left <> cap || t.nshadow <> 0 then begin
    (* ctrl first: FULL must always imply a well-typed slot. *)
    Bytes.fill c.ctrl 0 (Bytes.length c.ctrl) ctrl_empty;
    Array.fill c.keys 0 (Array.length c.keys) (dummy ());
    Array.fill c.vals 0 (Array.length c.vals) (dummy ());
    t.items <- 0;
    t.growth_left <- cap;
    t.nshadow <- 0;
    set_shadow t None
  end

let reset_repr (t : repr) =
  let buckets = t.initial_buckets in
  t.c <- make_core buckets;
  t.items <- 0;
  t.growth_left <- capacity_of_buckets buckets;
  t.nshadow <- 0;
  set_shadow t None

let copy_core (c : ('a, 'b) core) : ('a, 'b) core =
  {
    ctrl = Bytes.copy c.ctrl;
    keys = Array.copy c.keys;
    vals = Array.copy c.vals;
    mask = c.mask;
  }

(* Shallow content copy: keys/values (and the immutable stack spines)
   are shared, all structure is fresh (API §2.9). Plain recursion is
   fine on the uniform untyped instance; depth <= 2. *)
let rec copy_repr (t : repr) : repr =
  {
    c = copy_core t.c;
    items = t.items;
    growth_left = t.growth_left;
    shadow =
      (Obj.magic
         (match get_shadow t with
          | None -> None
          | Some s -> Some (copy_repr s))
        : (Obj.t, (Obj.t * Obj.t) list) t option);
    nshadow = t.nshadow;
    seed = t.seed;
    initial_buckets = t.initial_buckets;
  }

let stats_repr (t : repr) =
  let c = t.c in
  let buckets = c.mask + 1 in
  (* Per-distinct-key "bucket length" = 1 + its stack length; computed
     two-phase, no hashing (design §3). *)
  let shadow_entries = ref 0 in
  let mbl = ref (if t.items > 0 then 1 else 0) in
  (match get_shadow t with
  | None -> ()
  | Some s ->
    let cs = s.c in
    for i = 0 to cs.mask do
      if is_full_byte (Bytes.unsafe_get cs.ctrl i) then begin
        incr shadow_entries;
        let len = 1 + List.length (stack_of (Array.unsafe_get cs.vals i)) in
        if len > !mbl then mbl := len
      end
    done);
  let histo = Array.make (!mbl + 1) 0 in
  histo.(0) <- buckets - t.items;
  if t.items > 0 then histo.(1) <- t.items - !shadow_entries;
  (match get_shadow t with
  | None -> ()
  | Some s ->
    let cs = s.c in
    for i = 0 to cs.mask do
      if is_full_byte (Bytes.unsafe_get cs.ctrl i) then begin
        let len = 1 + List.length (stack_of (Array.unsafe_get cs.vals i)) in
        histo.(len) <- histo.(len) + 1
      end
    done);
  {
    num_bindings = length_repr t;
    num_buckets = buckets;
    max_bucket_length = !mbl;
    bucket_histogram = histo;
  }

(* Lazy two-phase sequence; the core snapshot and the shadow option are
   captured eagerly at [to_seq] time (mirroring stdlib capturing the
   bucket array); cells are read at force time. Unspecified under
   mutation, memory-safe (retired cores are never written). *)
let to_seq_repr (t : repr) : (Obj.t * Obj.t) Seq.t =
  let c = t.c in
  let shadow = get_shadow t in
  let rec phase2_stack stack cs i () =
    match stack with
    | (k, v) :: rest -> Seq.Cons ((k, v), phase2_stack rest cs i)
    | [] -> phase2 cs (i + 1) ()
  and phase2 cs i () =
    if i > cs.mask then Seq.Nil
    else if is_full_byte (Bytes.unsafe_get cs.ctrl i) then
      phase2_stack (stack_of (Array.unsafe_get cs.vals i)) cs i ()
    else phase2 cs (i + 1) ()
  and phase1 i () =
    if i > c.mask then
      match shadow with
      | None -> Seq.Nil
      | Some s -> phase2 s.c 0 ()
    else if is_full_byte (Bytes.unsafe_get c.ctrl i) then
      Seq.Cons
        ((Array.unsafe_get c.keys i, Array.unsafe_get c.vals i), phase1 (i + 1))
    else phase1 (i + 1) ()
  in
  phase1 0

(* ------------------------------------------------------------------ *)
(* Generic (polymorphic) interface                                     *)
(* ------------------------------------------------------------------ *)

module GenericEqh = struct
  (* stdlib generic equality is [compare ... = 0], NOT (=): nan keys
     are found (API §2.4). Argument orders are stdlib's. *)
  let eq_find (q : Obj.t) (s : Obj.t) = Stdlib.compare q s = 0
  let eq_upd (s : Obj.t) (q : Obj.t) = Stdlib.compare s q = 0
  let hash seed (k : Obj.t) = seeded_hash_param 10 100 seed k

  (* caml_hash_exn: deterministic, no user code; re-hashing stored
     keys cannot raise (insertion already hashed them). *)
  let pure_hash = true
end

module Gen = Engine (GenericEqh)

let create ?(random = is_randomized ()) initial_capacity =
  let buckets = max 16 (buckets_for_capacity (max initial_capacity 1)) in
  let seed = if random then Rng.bits () else 0 in
  of_repr (make_table ~seed buckets)

let clear t = clear_repr (repr t)
let reset t = reset_repr (repr t)
let copy t = of_repr (copy_repr (repr t))
let length t = length_repr (repr t)
let stats t = stats_repr (repr t)

let add t key v = Gen.add (repr t) (Obj.repr key) (Obj.repr v)
let replace t key v = Gen.replace (repr t) (Obj.repr key) (Obj.repr v)
let remove t key = Gen.remove (repr t) (Obj.repr key)
let find t key = Obj.obj (Gen.find (repr t) (Obj.repr key))

let find_opt (type b) t key : b option =
  (* Obj.t option and b option share representation. *)
  (Obj.magic (Gen.find_opt (repr t) (Obj.repr key)) : b option)

let find_all (type b) t key : b list =
  (Obj.magic (Gen.find_all (repr t) (Obj.repr key)) : b list)

let mem t key = Gen.mem (repr t) (Obj.repr key)

let iter f t = iter_repr (fun k v -> f (Obj.obj k) (Obj.obj v)) (repr t)

let fold f t init =
  fold_repr (fun k v acc -> f (Obj.obj k) (Obj.obj v) acc) (repr t) init

let filter_map_inplace f t =
  Gen.filter_map_inplace
    (fun k v ->
      match f (Obj.obj k) (Obj.obj v) with
      | Some v' -> Some (Obj.repr v')
      | None -> None)
    (repr t)

let to_seq t =
  Seq.map (fun (k, v) -> (Obj.obj k, Obj.obj v)) (to_seq_repr (repr t))

let to_seq_keys m = Seq.map fst (to_seq m)
let to_seq_values m = Seq.map snd (to_seq m)

let add_seq tbl i = Seq.iter (fun (k, v) -> add tbl k v) i
let replace_seq tbl i = Seq.iter (fun (k, v) -> replace tbl k v) i

let of_seq i =
  let tbl = create 16 in
  replace_seq tbl i;
  tbl

(* rebuild: hash-independent enumeration of the source (design §3 —
   the source may have been laid out by a different hash function,
   which is rebuild's documented use case). *)

let is_valid_core (c : Obj.t) =
  Obj.is_block c
  && Obj.size c = 4
  && Obj.tag (Obj.field c 0) = Obj.string_tag
  && Obj.is_int (Obj.field c 3)
  && (let mask = (Obj.obj (Obj.field c 3) : int) in
      let buckets = mask + 1 in
      buckets >= 8
      && buckets land mask = 0
      && Bytes.length (Obj.obj (Obj.field c 0) : Bytes.t)
         = buckets + G.width
      && Obj.tag (Obj.field c 1) = 0
      && Array.length (Obj.obj (Obj.field c 1) : Obj.t array) = buckets
      && Obj.tag (Obj.field c 2) = 0
      && Array.length (Obj.obj (Obj.field c 2) : Obj.t array) = buckets)

let is_valid_repr (t : repr) =
  let r = Obj.repr t in
  Obj.is_block r
  && Obj.size r = 7
  && is_valid_core (Obj.field r 0)
  && (let sh = Obj.field r 3 in
      (* shadow: None, or Some of a table whose core is well-formed *)
      Obj.is_int sh
      || (Obj.is_block sh
          && Obj.size sh = 1
          && (let s = Obj.field sh 0 in
              Obj.is_block s && Obj.size s = 7 && is_valid_core (Obj.field s 0))))

(* Defensive walk of a stored shadow stack (used only by [rebuild],
   whose input may be a corrupted/foreign unmarshaled value): checks
   list/tuple shape cell by cell, with a budget bounding hostile cyclic
   structures. Returns the entries oldest-first (stored order is
   newest-first; prepending while walking reverses it). *)
let validated_stack_oldest_first (v : Obj.t) =
  let bad () = invalid_arg "Swiss: unsupported hash table format" in
  let acc = ref [] in
  let cell = ref v in
  let budget = ref (1 lsl 30) in
  let continue_ = ref true in
  while !continue_ do
    decr budget;
    if !budget < 0 then bad ();
    let c = !cell in
    if Obj.is_int c then
      if (Obj.obj c : int) = 0 then continue_ := false else bad ()
    else if Obj.tag c = 0 && Obj.size c = 2 then begin
      let entry = Obj.field c 0 in
      if Obj.is_block entry && Obj.tag entry = 0 && Obj.size entry = 2 then begin
        acc := (Obj.field entry 0, Obj.field entry 1) :: !acc;
        cell := Obj.field c 1
      end
      else bad ()
    end
    else bad ()
  done;
  !acc

let rebuild ?(random = is_randomized ()) tbl =
  let t = repr tbl in
  if not (is_valid_repr t) then
    invalid_arg "Swiss: unsupported hash table format";
  let buckets = max 16 (t.c.mask + 1) in
  let seed = if random then Rng.bits () else t.seed in
  let nt = make_table ~seed buckets in
  nt.initial_buckets <- t.initial_buckets;
  (* pass 1: shadowed (older) bindings, oldest-first per key *)
  (match get_shadow t with
  | None -> ()
  | Some s ->
    let cs = s.c in
    for i = 0 to cs.mask do
      if is_full_byte (Bytes.unsafe_get cs.ctrl i) then
        List.iter
          (fun (k0, v0) -> Gen.add nt k0 v0)
          (validated_stack_oldest_first (Array.unsafe_get cs.vals i))
    done);
  (* pass 2: current bindings, added last = most recent *)
  let c = t.c in
  for i = 0 to c.mask do
    if is_full_byte (Bytes.unsafe_get c.ctrl i) then
      Gen.add nt (Array.unsafe_get c.keys i) (Array.unsafe_get c.vals i)
  done;
  of_repr nt

(* ------------------------------------------------------------------ *)
(* Functorial interface                                                *)
(* ------------------------------------------------------------------ *)

module type HashedType = sig
  type t

  val equal : t -> t -> bool
  val hash : t -> int
end

module type SeededHashedType = sig
  type t

  val equal : t -> t -> bool
  val seeded_hash : int -> t -> int
end

module type S = sig
  type key
  type !'a t

  val create : int -> 'a t
  val clear : 'a t -> unit
  val reset : 'a t -> unit
  val copy : 'a t -> 'a t
  val add : 'a t -> key -> 'a -> unit
  val remove : 'a t -> key -> unit
  val find : 'a t -> key -> 'a
  val find_opt : 'a t -> key -> 'a option
  val find_all : 'a t -> key -> 'a list
  val replace : 'a t -> key -> 'a -> unit
  val mem : 'a t -> key -> bool
  val iter : (key -> 'a -> unit) -> 'a t -> unit
  val filter_map_inplace : (key -> 'a -> 'a option) -> 'a t -> unit
  val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
  val length : 'a t -> int
  val stats : 'a t -> statistics
  val to_seq : 'a t -> (key * 'a) Seq.t
  val to_seq_keys : _ t -> key Seq.t
  val to_seq_values : 'a t -> 'a Seq.t
  val add_seq : 'a t -> (key * 'a) Seq.t -> unit
  val replace_seq : 'a t -> (key * 'a) Seq.t -> unit
  val of_seq : (key * 'a) Seq.t -> 'a t
end

module type SeededS = sig
  type key
  type !'a t

  val create : ?random:bool -> int -> 'a t
  val clear : 'a t -> unit
  val reset : 'a t -> unit
  val copy : 'a t -> 'a t
  val add : 'a t -> key -> 'a -> unit
  val remove : 'a t -> key -> unit
  val find : 'a t -> key -> 'a
  val find_opt : 'a t -> key -> 'a option
  val find_all : 'a t -> key -> 'a list
  val replace : 'a t -> key -> 'a -> unit
  val mem : 'a t -> key -> bool
  val iter : (key -> 'a -> unit) -> 'a t -> unit
  val filter_map_inplace : (key -> 'a -> 'a option) -> 'a t -> unit
  val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
  val length : 'a t -> int
  val stats : 'a t -> statistics
  val to_seq : 'a t -> (key * 'a) Seq.t
  val to_seq_keys : _ t -> key Seq.t
  val to_seq_values : 'a t -> 'a Seq.t
  val add_seq : 'a t -> (key * 'a) Seq.t -> unit
  val replace_seq : 'a t -> (key * 'a) Seq.t -> unit
  val of_seq : (key * 'a) Seq.t -> 'a t
end

(* The engine instantiation shared by the seeded functors. The portable
   variants pass H's (portable) functions straight through; the legacy
   variants wrap them with Obj.magic_portable — sound here because the
   resulting module is only ever exposed at an unannotated signature,
   so the stronger internal mode never escapes. *)
module MakeSeededPortable (H : sig @@ portable
  include SeededHashedType
end) : sig @@ portable
  include SeededS with type key = H.t
end = struct
  type key = H.t
  type nonrec 'a t = (key, 'a) t

  module E = Engine (struct
    let eq_find (q : Obj.t) (s : Obj.t) =
      H.equal (Obj.obj q : key) (Obj.obj s : key)

    let eq_upd (s : Obj.t) (q : Obj.t) =
      H.equal (Obj.obj s : key) (Obj.obj q : key)

    (* Functor-supplied hashes get a single-multiply finalizer: h2 is
       drawn from bits 23..29, which low-entropy user hashes (e.g. the
       mli's own `let hash i = i land max_int` example) leave all-zero,
       nullifying the SWAR tag filter (measured 9.6 eq calls per miss
       vs 0.08). One Fibonacci-style multiply populates the whole
       30-bit window. The generic path is already Murmur3-finalized and
       stays unmixed. *)
    let hash seed (k : Obj.t) =
      let h = H.seeded_hash seed (Obj.obj k : key) in
      (h * 0x2545F4914F6CDD1D) lsr 33 land 0x3FFFFFFF

    (* user-supplied hash: may raise or reenter — copying purge only *)
    let pure_hash = false
  end)

  let create ?(random = is_randomized ()) initial_capacity =
    let buckets = max 16 (buckets_for_capacity (max initial_capacity 1)) in
    let seed = if random then Rng.bits () else 0 in
    (of_repr (make_table ~seed buckets) : 'a t)

  let clear t = clear_repr (repr t)
  let reset t = reset_repr (repr t)
  let copy t = of_repr (copy_repr (repr t))
  let length t = length_repr (repr t)
  let stats t = stats_repr (repr t)
  let add t key v = E.add (repr t) (Obj.repr key) (Obj.repr v)
  let replace t key v = E.replace (repr t) (Obj.repr key) (Obj.repr v)
  let remove t key = E.remove (repr t) (Obj.repr key)
  let find t key = Obj.obj (E.find (repr t) (Obj.repr key))

  let find_opt (type a) t key : a option =
    (Obj.magic (E.find_opt (repr t) (Obj.repr key)) : a option)

  let find_all (type a) t key : a list =
    (Obj.magic (E.find_all (repr t) (Obj.repr key)) : a list)

  let mem t key = E.mem (repr t) (Obj.repr key)
  let iter f t = iter_repr (fun k v -> f (Obj.obj k) (Obj.obj v)) (repr t)

  let fold f t init =
    fold_repr (fun k v acc -> f (Obj.obj k) (Obj.obj v) acc) (repr t) init

  let filter_map_inplace f t =
    E.filter_map_inplace
      (fun k v ->
        match f (Obj.obj k) (Obj.obj v) with
        | Some v' -> Some (Obj.repr v')
        | None -> None)
      (repr t)

  let to_seq t =
    Seq.map (fun (k, v) -> (Obj.obj k, Obj.obj v)) (to_seq_repr (repr t))

  let to_seq_keys m = Seq.map fst (to_seq m)
  let to_seq_values m = Seq.map snd (to_seq m)
  let add_seq tbl i = Seq.iter (fun (k, v) -> add tbl k v) i
  let replace_seq tbl i = Seq.iter (fun (k, v) -> replace tbl k v) i

  let of_seq i =
    let tbl = create 16 in
    replace_seq tbl i;
    tbl
end
[@@inline available]

module MakeSeeded (H : SeededHashedType) : SeededS with type key = H.t =
  MakeSeededPortable (struct
    type t = H.t

    let equal = Obj.magic_portable H.equal
    let seeded_hash = Obj.magic_portable H.seeded_hash
  end)
[@@inline available]

module MakePortable (H : sig @@ portable
  include HashedType
end) : sig @@ portable
  include S with type key = H.t
end = struct
  include MakeSeededPortable (struct
    type t = H.t

    let equal = H.equal
    let seeded_hash (_seed : int) x = H.hash x
  end)

  let create sz = create ~random:false sz

  let of_seq i =
    let tbl = create 16 in
    replace_seq tbl i;
    tbl
end
[@@inline available]

module Make (H : HashedType) : S with type key = H.t = MakePortable (struct
  type t = H.t

  let equal = Obj.magic_portable H.equal
  let hash = Obj.magic_portable H.hash
end)
[@@inline available]


(* Differential fuzzer: Swiss vs Stdlib.Hashtbl (oracle).

   For each random operation sequence we maintain mirrored table pairs (a
   Swiss table and a stdlib Hashtbl created with the same parameters,
   ~random:false for determinism) and apply identical randomly chosen
   operations to both sides, asserting observational equivalence after every
   operation (cheap checks) and periodically in depth:
     - length equal
     - for keys of the active universe: find_opt / find_all (exact list,
       per-key order is specified!) / mem equal, find raises Not_found
       consistently
     - multiset of (key, value) bindings from fold equal (sorted; global
       iteration order between distinct keys is a documented deviation and
       is NOT compared)
     - per-key visit order of fold/iter/to_seq on the Swiss side equals
       find_all (most-recent-first)
     - stored key OBJECTS per key physically identical to stdlib's (checks
       replace's documented in-place key overwrite); enabled for int/string
       universes only
     - swiss-internal stats sanity: num_bindings = length, histogram sums
       to num_buckets (stats bucket values are a documented deviation and
       are never compared with stdlib's)
     - clear keeps capacity / reset returns to create-time num_buckets
       (Swiss-internal check, not stdlib parity)

   Failures print the universe, the reproducing seed (Random.State.make
   [|uid; seq_idx|]) and the tail of the op trace (ring buffer of the last
   50 ops).

   Documented deviations (docs/design.md section 1) intentionally NOT
   tested: inter-key iteration order, stats bucket values vs stdlib,
   cyclic/closure keys with add, non-equivalence equal, side-effecting
   hash with filter_map_inplace, rebuild's num_buckets. *)

let ops_per_seq = 2000
let seqs_per_universe = 400
let full_check_every = 20
let max_pairs = 3
let ring_size = 50

(* ------------------------------------------------------------------ *)
(* Common signature both implementations are wrapped into.            *)
(* ------------------------------------------------------------------ *)

module type TBL = sig
  type key
  type 'a t

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
  val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
  val length : 'a t -> int
  val to_seq : 'a t -> (key * 'a) Seq.t
  val add_seq : 'a t -> (key * 'a) Seq.t -> unit
  val replace_seq : 'a t -> (key * 'a) Seq.t -> unit
  val of_seq : (key * 'a) Seq.t -> 'a t
  val filter_map_inplace : (key -> 'a -> 'a option) -> 'a t -> unit
  val rebuild : 'a t -> 'a t (* copy for functor routes (S has no rebuild) *)
  val stats_num_bindings : 'a t -> int
  val stats_num_buckets : 'a t -> int
  val stats_consistent : 'a t -> bool
end

let swiss_stats_ok (s : Swiss.statistics) =
  Array.fold_left ( + ) 0 s.Swiss.bucket_histogram = s.Swiss.num_buckets
  && Array.length s.Swiss.bucket_histogram = s.Swiss.max_bucket_length + 1

let std_stats_ok (s : Hashtbl.statistics) =
  Array.fold_left ( + ) 0 s.Hashtbl.bucket_histogram = s.Hashtbl.num_buckets
  && Array.length s.Hashtbl.bucket_histogram = s.Hashtbl.max_bucket_length + 1

(* Generic (polymorphic-key) adapters. *)

module SwissG (Key : sig
  type t
end) : TBL with type key = Key.t = struct
  type key = Key.t
  type 'a t = (key, 'a) Swiss.t

  let create n = Swiss.create ~random:false n
  let clear = Swiss.clear
  let reset = Swiss.reset
  let copy = Swiss.copy
  let add = Swiss.add
  let remove = Swiss.remove
  let find = Swiss.find
  let find_opt = Swiss.find_opt
  let find_all = Swiss.find_all
  let replace = Swiss.replace
  let mem = Swiss.mem
  let iter = Swiss.iter
  let fold = Swiss.fold
  let length = Swiss.length
  let to_seq = Swiss.to_seq
  let add_seq = Swiss.add_seq
  let replace_seq = Swiss.replace_seq
  let of_seq = Swiss.of_seq
  let filter_map_inplace = Swiss.filter_map_inplace
  let rebuild t = Swiss.rebuild ~random:false t
  let stats_num_bindings t = (Swiss.stats t).Swiss.num_bindings
  let stats_num_buckets t = (Swiss.stats t).Swiss.num_buckets
  let stats_consistent t = swiss_stats_ok (Swiss.stats t)
end

module StdG (Key : sig
  type t
end) : TBL with type key = Key.t = struct
  type key = Key.t
  type 'a t = (key, 'a) Hashtbl.t

  let create n = Hashtbl.create ~random:false n
  let clear = Hashtbl.clear
  let reset = Hashtbl.reset
  let copy = Hashtbl.copy
  let add = Hashtbl.add
  let remove = Hashtbl.remove
  let find = Hashtbl.find
  let find_opt = Hashtbl.find_opt
  let find_all = Hashtbl.find_all
  let replace = Hashtbl.replace
  let mem = Hashtbl.mem
  let iter = Hashtbl.iter
  let fold = Hashtbl.fold
  let length = Hashtbl.length
  let to_seq = Hashtbl.to_seq
  let add_seq = Hashtbl.add_seq
  let replace_seq = Hashtbl.replace_seq
  let of_seq = Hashtbl.of_seq
  let filter_map_inplace = Hashtbl.filter_map_inplace
  let rebuild t = Hashtbl.rebuild ~random:false t
  let stats_num_bindings t = (Hashtbl.stats t).Hashtbl.num_bindings
  let stats_num_buckets t = (Hashtbl.stats t).Hashtbl.num_buckets
  let stats_consistent t = std_stats_ok (Hashtbl.stats t)
end

(* Functor routes: same H on both sides. *)

module IntH = struct
  type t = int

  let equal = Int.equal
  let hash x = Hashtbl.hash x
end

module SIntH = struct
  type t = int

  let equal = Int.equal
  let seeded_hash seed x = Hashtbl.seeded_hash seed x
end

module SwissMakeInt : TBL with type key = int = struct
  include Swiss.Make (IntH)

  let rebuild = copy
  let stats_num_bindings t = (stats t).Swiss.num_bindings
  let stats_num_buckets t = (stats t).Swiss.num_buckets
  let stats_consistent t = swiss_stats_ok (stats t)
end

module StdMakeInt : TBL with type key = int = struct
  include Hashtbl.Make (IntH)

  let rebuild = copy
  let stats_num_bindings t = (stats t).Hashtbl.num_bindings
  let stats_num_buckets t = (stats t).Hashtbl.num_buckets
  let stats_consistent t = std_stats_ok (stats t)
end

module SwissSeededInt : TBL with type key = int = struct
  include Swiss.MakeSeeded (SIntH)

  (* fixed seed for determinism *)
  let create n = create ~random:false n
  let rebuild = copy
  let stats_num_bindings t = (stats t).Swiss.num_bindings
  let stats_num_buckets t = (stats t).Swiss.num_buckets
  let stats_consistent t = swiss_stats_ok (stats t)
end

module StdSeededInt : TBL with type key = int = struct
  include Hashtbl.MakeSeeded (SIntH)

  let create n = create ~random:false n
  let rebuild = copy
  let stats_num_bindings t = (stats t).Hashtbl.num_bindings
  let stats_num_buckets t = (stats t).Hashtbl.num_buckets
  let stats_consistent t = std_stats_ok (stats t)
end

(* ------------------------------------------------------------------ *)
(* Key universes                                                      *)
(* ------------------------------------------------------------------ *)

module type KEYGEN = sig
  type t

  val gen : Random.State.t -> t
  val show : t -> string

  (* compare stored key objects with stdlib's via (==)? (safe for ints and
     strings; floats are exempted to avoid harness-level reboxing noise) *)
  val check_key_identity : bool
end

module IntGen = struct
  type t = int

  let check_key_identity = true

  (* small universe 0..15 forces duplicate stacks; occasional 0..10000
     forces growth *)
  let gen rng =
    if Random.State.int rng 8 = 0 then Random.State.int rng 10_001
    else Random.State.int rng 16

  let show = string_of_int
end

module StringGen = struct
  type t = string

  let check_key_identity = true

  let gen rng =
    if Random.State.int rng 4 = 0 then
      (* freshly allocated, so compare-equal but physically distinct keys
         occur all the time *)
      String.make (1 + Random.State.int rng 2) (Char.chr (97 + Random.State.int rng 4))
    else if Random.State.int rng 8 = 0 then string_of_int (Random.State.int rng 10_001)
    else string_of_int (Random.State.int rng 16)

  let show s = Printf.sprintf "%S" s
end

module FloatGen = struct
  type t = float

  let check_key_identity = false

  (* compare nan nan = 0 and compare (-0.) 0. = 0: nan is ONE key (findable),
     -0. and 0. are the SAME key, for both implementations *)
  let specials = [| nan; infinity; neg_infinity; 0.0; -0.0; 1.5; -1.5; 3.25 |]

  let gen rng =
    match Random.State.int rng 8 with
    | 0 | 1 -> specials.(Random.State.int rng (Array.length specials))
    | 2 -> 0.0 /. 0.0 (* a nan again *)
    | 3 -> float_of_int (Random.State.int rng 10_001)
    | _ -> float_of_int (Random.State.int rng 16)

  let show f = Printf.sprintf "%h" f
end

(* ------------------------------------------------------------------ *)
(* The differential harness                                           *)
(* ------------------------------------------------------------------ *)

module Run
    (A : TBL)
    (B : TBL with type key = A.key)
    (K : KEYGEN with type t = A.key) =
struct
  exception Diff of string

  let failf fmt = Printf.ksprintf (fun s -> raise (Diff s)) fmt
  let show_opt = function None -> "None" | Some v -> "Some " ^ string_of_int v
  let show_list l = "[" ^ String.concat "; " (List.map string_of_int l) ^ "]"
  let show_res = function Ok v -> "Ok " ^ string_of_int v | Error () -> "Not_found"

  type pair = { mutable a : int A.t; mutable b : int B.t; id : int }

  let run_seq ~name ~uid ~seq_idx =
    let rng = Random.State.make [| uid; seq_idx |] in
    (* --- op trace ring buffer --- *)
    let ring = Array.make ring_size "" in
    let ring_n = ref 0 in
    let logf fmt =
      Printf.ksprintf
        (fun s ->
          ring.(!ring_n mod ring_size) <- s;
          incr ring_n)
        fmt
    in
    let dump_ring () =
      Printf.eprintf "Last %d ops (oldest first):\n"
        (min !ring_n ring_size);
      for i = max 0 (!ring_n - ring_size) to !ring_n - 1 do
        Printf.eprintf "  #%d %s\n" i ring.(i mod ring_size)
      done;
      flush stderr
    in
    (* --- active key universe (deduplicated, structural) --- *)
    let keys = ref [||] in
    let nkeys = ref 0 in
    let seen = Hashtbl.create 64 in
    let register k =
      if not (Hashtbl.mem seen k) then begin
        Hashtbl.add seen k ();
        if !nkeys = Array.length !keys then begin
          let arr = Array.make (max 64 (2 * !nkeys)) k in
          Array.blit !keys 0 arr 0 !nkeys;
          keys := arr
        end;
        !keys.(!nkeys) <- k;
        incr nkeys
      end
    in
    let pick_key () =
      let k =
        if !nkeys = 0 || Random.State.int rng 3 = 0 then K.gen rng
        else !keys.(Random.State.int rng !nkeys)
      in
      register k;
      k
    in
    (* --- table pairs (originals + live copies, fuzzed alike) --- *)
    let n0 =
      match Random.State.int rng 6 with
      | 0 -> -3 + Random.State.int rng 4 (* negative/zero: must not raise *)
      | 1 -> 500 + Random.State.int rng 600
      | _ -> Random.State.int rng 40
    in
    let next_id = ref 0 in
    let mk_pair a b =
      let id = !next_id in
      incr next_id;
      { a; b; id }
    in
    let pairs = ref [| mk_pair (A.create n0) (B.create n0) |] in
    let nb0 = A.stats_num_buckets (!pairs).(0).a in
    (* --- checks --- *)
    let check_len p =
      let la = A.length p.a and lb = B.length p.b in
      if la <> lb then failf "pair#%d length: swiss=%d stdlib=%d" p.id la lb
    in
    let probe p k =
      let oa = A.find_opt p.a k and ob = B.find_opt p.b k in
      if compare oa ob <> 0 then
        failf "pair#%d find_opt %s: swiss=%s stdlib=%s" p.id (K.show k)
          (show_opt oa) (show_opt ob);
      let la = A.find_all p.a k and lb = B.find_all p.b k in
      if compare la lb <> 0 then
        failf "pair#%d find_all %s: swiss=%s stdlib=%s" p.id (K.show k)
          (show_list la) (show_list lb);
      let ma = A.mem p.a k and mb = B.mem p.b k in
      if ma <> mb then
        failf "pair#%d mem %s: swiss=%b stdlib=%b" p.id (K.show k) ma mb;
      let fa = try Ok (A.find p.a k) with Not_found -> Error () in
      let fb = try Ok (B.find p.b k) with Not_found -> Error () in
      if compare fa fb <> 0 then
        failf "pair#%d find %s: swiss=%s stdlib=%s" p.id (K.show k)
          (show_res fa) (show_res fb)
    in
    let probe_random p =
      if !nkeys > 0 then begin
        probe p !keys.(Random.State.int rng !nkeys);
        probe p !keys.(Random.State.int rng !nkeys)
      end
    in
    (* group a visit-order (key, value) list per key; values end up in
       reverse visit order *)
    let group_values visit =
      let acc = Hashtbl.create 16 in
      List.iter
        (fun (k, v) ->
          let cur = try Hashtbl.find acc k with Not_found -> [] in
          Hashtbl.replace acc k (v :: cur))
        visit;
      acc
    in
    let full_check p =
      check_len p;
      let n = A.length p.a in
      let san = A.stats_num_bindings p.a in
      if san <> n then
        failf "pair#%d swiss stats.num_bindings=%d but length=%d" p.id san n;
      let sbn = B.stats_num_bindings p.b in
      if sbn <> n then
        failf "pair#%d stdlib stats.num_bindings=%d but length=%d" p.id sbn n;
      if not (A.stats_consistent p.a) then
        failf "pair#%d swiss stats: histogram inconsistent with num_buckets" p.id;
      for i = 0 to !nkeys - 1 do
        probe p !keys.(i)
      done;
      (* fold multiset equality (order across keys is unspecified) *)
      let ra = A.fold (fun k v acc -> (k, v) :: acc) p.a [] in
      let rb = B.fold (fun k v acc -> (k, v) :: acc) p.b [] in
      let sa = List.sort compare ra and sb = List.sort compare rb in
      if compare sa sb <> 0 then
        failf
          "pair#%d fold multiset mismatch: swiss has %d bindings, stdlib %d \
           (contents differ)"
          p.id (List.length ra) (List.length rb);
      (* swiss-internal: iter and to_seq agree with fold as multisets *)
      let ri = ref [] in
      A.iter (fun k v -> ri := (k, v) :: !ri) p.a;
      if compare (List.sort compare !ri) sa <> 0 then
        failf "pair#%d swiss iter multiset differs from fold multiset" p.id;
      let ls = List.of_seq (A.to_seq p.a) in
      if compare (List.sort compare ls) sa <> 0 then
        failf "pair#%d swiss to_seq multiset differs from fold multiset" p.id;
      (* per-key visit order is most-recent-first, i.e. equals find_all
         (which was cross-checked against stdlib just above) *)
      let check_order what visit =
        let g = group_values visit in
        Hashtbl.iter
          (fun k rev_vals ->
            let expect = A.find_all p.a k in
            if compare (List.rev rev_vals) expect <> 0 then
              failf "pair#%d swiss %s per-key order for %s: visited=%s find_all=%s"
                p.id what (K.show k)
                (show_list (List.rev rev_vals))
                (show_list expect))
          g
      in
      check_order "fold" (List.rev ra);
      check_order "iter" (List.rev !ri);
      check_order "to_seq" ls;
      (* replace/add must store the argument key OBJECT (api.md 2.6): for
         each key, the recency-ordered key objects visited must be
         physically identical to the ones stdlib stores *)
      if K.check_key_identity then begin
        let group_keys visit =
          let acc = Hashtbl.create 16 in
          List.iter
            (fun (k, _) ->
              let cur = try Hashtbl.find acc k with Not_found -> [] in
              Hashtbl.replace acc k (k :: cur))
            visit;
          acc
        in
        let ga = group_keys (List.rev ra) and gb = group_keys (List.rev rb) in
        Hashtbl.iter
          (fun k la ->
            let lb = try Hashtbl.find gb k with Not_found -> [] in
            if
              List.length la <> List.length lb
              || not (List.for_all2 (fun x y -> x == y) (List.rev la) (List.rev lb))
            then
              failf "pair#%d stored key objects for %s differ physically from stdlib"
                p.id (K.show k))
          ga
      end
    in
    (* --- operations --- *)
    let fmi_f _k v = if v mod 3 <> 0 then Some (v + 1) else None in
    let gen_small_list () =
      List.init (Random.State.int rng 6) (fun _ ->
          let k = pick_key () in
          (k, Random.State.int rng 100))
    in
    let weights =
      if seq_idx mod 2 = 0 then
        [| (`Add, 60); (`Remove, 30); (`Replace, 28); (`Probe, 20); (`Length, 4);
           (`Copy, 4); (`Clear, 2); (`Reset, 2); (`Fmi, 6); (`Rebuild, 4);
           (`AddSeq, 8); (`ReplaceSeq, 8); (`OfSeq, 4) |]
      else
        (* growth profile: add-heavy, no clear/reset, so tables get large *)
        [| (`Add, 90); (`Remove, 20); (`Replace, 30); (`Probe, 15); (`Length, 2);
           (`Copy, 3); (`Clear, 0); (`Reset, 0); (`Fmi, 4); (`Rebuild, 3);
           (`AddSeq, 10); (`ReplaceSeq, 8); (`OfSeq, 2) |]
    in
    let total_weight = Array.fold_left (fun s (_, w) -> s + w) 0 weights in
    let pick_op () =
      let r = ref (Random.State.int rng total_weight) in
      let res = ref `Add in
      (try
         Array.iter
           (fun (op, w) ->
             if !r < w then begin
               res := op;
               raise Exit
             end
             else r := !r - w)
           weights
       with Exit -> ());
      !res
    in
    let body () =
      for opi = 1 to ops_per_seq do
        let p = (!pairs).(Random.State.int rng (Array.length !pairs)) in
        (match pick_op () with
        | `Add ->
            let k = pick_key () and v = Random.State.int rng 100 in
            logf "add p#%d %s %d" p.id (K.show k) v;
            A.add p.a k v;
            B.add p.b k v;
            probe p k
        | `Remove ->
            let k = pick_key () in
            logf "remove p#%d %s" p.id (K.show k);
            A.remove p.a k;
            B.remove p.b k;
            probe p k
        | `Replace ->
            let k = pick_key () and v = Random.State.int rng 100 in
            logf "replace p#%d %s %d" p.id (K.show k) v;
            A.replace p.a k v;
            B.replace p.b k v;
            probe p k
        | `Probe ->
            let k = pick_key () in
            logf "probe p#%d %s" p.id (K.show k);
            probe p k
        | `Length ->
            logf "length p#%d" p.id;
            check_len p
        | `Copy ->
            let q = mk_pair (A.copy p.a) (B.copy p.b) in
            logf "copy p#%d -> p#%d" p.id q.id;
            if Array.length !pairs < max_pairs then
              pairs := Array.append !pairs [| q |]
            else (!pairs).(Random.State.int rng (Array.length !pairs)) <- q;
            (* copies must be independent: each pair is fuzzed against its
               own oracle from here on, and every per-op check below also
               re-verifies the lengths of all other pairs *)
            check_len q;
            probe_random q
        | `Clear ->
            logf "clear p#%d" p.id;
            let nb_before = A.stats_num_buckets p.a in
            A.clear p.a;
            B.clear p.b;
            let nb_after = A.stats_num_buckets p.a in
            if nb_after <> nb_before then
              failf "pair#%d clear changed swiss num_buckets: %d -> %d" p.id
                nb_before nb_after;
            check_len p
        | `Reset ->
            logf "reset p#%d" p.id;
            A.reset p.a;
            B.reset p.b;
            let nb = A.stats_num_buckets p.a in
            if nb <> nb0 then
              failf "pair#%d reset: swiss num_buckets=%d, create-time was %d"
                p.id nb nb0;
            check_len p
        | `Fmi ->
            logf "filter_map_inplace p#%d" p.id;
            A.filter_map_inplace fmi_f p.a;
            B.filter_map_inplace fmi_f p.b
        | `Rebuild ->
            logf "rebuild p#%d" p.id;
            p.a <- A.rebuild p.a;
            p.b <- B.rebuild p.b
        | `AddSeq ->
            let l = gen_small_list () in
            logf "add_seq p#%d (%d pairs)" p.id (List.length l);
            A.add_seq p.a (List.to_seq l);
            B.add_seq p.b (List.to_seq l);
            List.iter (fun (k, _) -> probe p k) l
        | `ReplaceSeq ->
            let l = gen_small_list () in
            logf "replace_seq p#%d (%d pairs)" p.id (List.length l);
            A.replace_seq p.a (List.to_seq l);
            B.replace_seq p.b (List.to_seq l);
            List.iter (fun (k, _) -> probe p k) l
        | `OfSeq ->
            logf "of_seq round-trip p#%d" p.id;
            let la = List.of_seq (A.to_seq p.a) in
            let lb = List.of_seq (B.to_seq p.b) in
            let a' = A.of_seq (List.to_seq la) in
            let b' = B.of_seq (List.to_seq lb) in
            let na = A.length a' and nb = B.length b' in
            if na <> nb then
              failf "pair#%d of_seq(to_seq) length: swiss=%d stdlib=%d" p.id na nb;
            let sa =
              List.sort compare (A.fold (fun k v acc -> (k, v) :: acc) a' [])
            in
            let sb =
              List.sort compare (B.fold (fun k v acc -> (k, v) :: acc) b' [])
            in
            if compare sa sb <> 0 then
              failf "pair#%d of_seq(to_seq) multiset mismatch (%d vs %d bindings)"
                p.id na nb);
        (* cheap invariants after EVERY op *)
        check_len p;
        probe_random p;
        Array.iter check_len !pairs;
        if opi mod full_check_every = 0 then Array.iter full_check !pairs
      done;
      Array.iter full_check !pairs
    in
    try body () with
    | Diff msg ->
        Printf.eprintf
          "\n=== DIFF FAILURE: universe=%s, seed=Random.State.make [|%d;%d|], after op #%d ===\n%s\n"
          name uid seq_idx !ring_n msg;
        dump_ring ();
        exit 1
    | e ->
        Printf.eprintf
          "\n=== EXCEPTION: universe=%s, seed=Random.State.make [|%d;%d|], after op #%d ===\n%s\n%s\n"
          name uid seq_idx !ring_n (Printexc.to_string e)
          (Printexc.get_backtrace ());
        dump_ring ();
        exit 1

  let run ~name ~uid =
    for seq_idx = 0 to seqs_per_universe - 1 do
      run_seq ~name ~uid ~seq_idx
    done;
    Printf.printf "diff[%s]: %d sequences x %d ops OK\n%!" name
      seqs_per_universe ops_per_seq
end

(* ------------------------------------------------------------------ *)
(* Instantiations                                                     *)
(* ------------------------------------------------------------------ *)

module IntKey = struct
  type t = int
end

module StrKey = struct
  type t = string
end

module FloKey = struct
  type t = float
end

module RunGenInt = Run (SwissG (IntKey)) (StdG (IntKey)) (IntGen)
module RunGenStr = Run (SwissG (StrKey)) (StdG (StrKey)) (StringGen)
module RunGenFlo = Run (SwissG (FloKey)) (StdG (FloKey)) (FloatGen)
module RunMakeInt = Run (SwissMakeInt) (StdMakeInt) (IntGen)
module RunSeededInt = Run (SwissSeededInt) (StdSeededInt) (IntGen)

let () =
  Printexc.record_backtrace true;
  RunGenInt.run ~name:"generic-int" ~uid:1;
  RunGenStr.run ~name:"generic-string" ~uid:2;
  RunGenFlo.run ~name:"generic-float" ~uid:3;
  RunMakeInt.run ~name:"Make(IntH)" ~uid:4;
  RunSeededInt.run ~name:"MakeSeeded(SIntH)" ~uid:5;
  print_endline "diff fuzzer OK"

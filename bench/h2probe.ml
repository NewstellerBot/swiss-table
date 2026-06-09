(* Probe for the h2-vs-identity-hash claim:
   with the mli's recommended functor hash (fun i -> i land max_int) and
   keys < 2^23, h2 = (h lsr 23) land 0x7f = 0 for every key, so SWAR tag
   filtering should match every FULL slot and inflate eq calls.
   We count eq calls per successful find. *)

let n = 100_000
let key_bound = 1 lsl 23 (* 8_388_608 *)

let eq_calls = ref 0

module IdentEq = struct
  type t = int
  let equal i j = incr eq_calls; i = j
  let hash i = i land max_int (* the swiss.mli §Functorial-interface example *)
end

module MixedEq = struct
  type t = int
  let equal i j = incr eq_calls; i = j
  let hash i = Stdlib.Hashtbl.hash i
end

module SwissIdent = Swiss.Make (IdentEq)
module SwissMixed = Swiss.Make (MixedEq)
module StdIdent = Stdlib.Hashtbl.Make (IdentEq)
module StdMixed = Stdlib.Hashtbl.Make (MixedEq)

(* distinct random keys in [0, bound) *)
let make_keys ~bound seed =
  let st = Random.State.make [| seed |] in
  let seen = Stdlib.Hashtbl.create (2 * n) in
  let keys = Array.make n 0 in
  let i = ref 0 in
  while !i < n do
    let k = Random.State.full_int st bound in
    if not (Stdlib.Hashtbl.mem seen k) then begin
      Stdlib.Hashtbl.add seen k ();
      keys.(!i) <- k;
      incr i
    end
  done;
  keys

let run name add find keys =
  Array.iter (fun k -> add k k) keys;
  eq_calls := 0;
  Array.iter (fun k -> ignore (find k)) keys;
  Printf.printf "%-42s eq/find(hit) = %.3f\n%!" name
    (float_of_int !eq_calls /. float_of_int n)

let () =
  let keys = make_keys ~bound:key_bound 42 in
  let keys_big = make_keys ~bound:max_int 43 in

  (let t = SwissIdent.create 16 in
   run "Swiss ident hash, keys < 2^23" (SwissIdent.replace t)
     (SwissIdent.find_opt t) keys);
  (let t = SwissMixed.create 16 in
   run "Swiss Hashtbl.hash, keys < 2^23" (SwissMixed.replace t)
     (SwissMixed.find_opt t) keys);
  (let t = StdIdent.create 16 in
   run "Stdlib ident hash, keys < 2^23" (StdIdent.replace t)
     (StdIdent.find_opt t) keys);
  (let t = StdMixed.create 16 in
   run "Stdlib Hashtbl.hash, keys < 2^23" (StdMixed.replace t)
     (StdMixed.find_opt t) keys);
  (* control: identity hash with high-entropy keys is fine in Swiss *)
  (let t = SwissIdent.create 16 in
   run "Swiss ident hash, keys < max_int" (SwissIdent.replace t)
     (SwissIdent.find_opt t) keys_big);

  (* misses: distinct keys not in the table *)
  let misses = make_keys ~bound:key_bound 4242 in
  let in_table = Stdlib.Hashtbl.create (2 * n) in
  Array.iter (fun k -> Stdlib.Hashtbl.replace in_table k ()) keys;
  let misses =
    Array.of_list
      (List.filter
         (fun k -> not (Stdlib.Hashtbl.mem in_table k))
         (Array.to_list misses))
  in
  let nm = Array.length misses in
  (let t = SwissIdent.create 16 in
   Array.iter (fun k -> SwissIdent.replace t k k) keys;
   eq_calls := 0;
   Array.iter (fun k -> ignore (SwissIdent.find_opt t k)) misses;
   Printf.printf "%-42s eq/find(miss) = %.3f (n=%d)\n%!"
     "Swiss ident hash, keys < 2^23" (float_of_int !eq_calls /. float_of_int nm) nm);
  (let t = SwissMixed.create 16 in
   Array.iter (fun k -> SwissMixed.replace t k k) keys;
   eq_calls := 0;
   Array.iter (fun k -> ignore (SwissMixed.find_opt t k)) misses;
   Printf.printf "%-42s eq/find(miss) = %.3f (n=%d)\n%!"
     "Swiss Hashtbl.hash, keys < 2^23" (float_of_int !eq_calls /. float_of_int nm) nm)

(* wall-clock sanity check on find hits and misses *)
let time name f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  let t1 = Unix.gettimeofday () in
  Printf.printf "%-42s %.1f ns/op (sink %d)\n%!" name
    ((t1 -. t0) /. float_of_int (10 * n) *. 1e9) r

let () =
  let keys = make_keys ~bound:key_bound 7 in
  let misses0 = make_keys ~bound:key_bound 77 in
  let in_t = Stdlib.Hashtbl.create (2*n) in
  Array.iter (fun k -> Stdlib.Hashtbl.replace in_t k ()) keys;
  let misses = Array.of_list (List.filteri (fun i k -> i < n && not (Stdlib.Hashtbl.mem in_t k)) (Array.to_list misses0)) in
  let ti = SwissIdent.create 16 and tm = SwissMixed.create 16 in
  Array.iter (fun k -> SwissIdent.replace ti k k) keys;
  Array.iter (fun k -> SwissMixed.replace tm k k) keys;
  time "TIME Swiss ident hit" (fun () ->
    let s = ref 0 in
    for _ = 1 to 10 do
      Array.iter (fun k -> if SwissIdent.mem ti k then incr s) keys
    done; !s);
  time "TIME Swiss mixed hit" (fun () ->
    let s = ref 0 in
    for _ = 1 to 10 do
      Array.iter (fun k -> if SwissMixed.mem tm k then incr s) keys
    done; !s);
  let nm = Array.length misses in
  let timem name f =
    let t0 = Unix.gettimeofday () in
    let r = f () in
    let t1 = Unix.gettimeofday () in
    Printf.printf "%-42s %.1f ns/op (sink %d)\n%!" name
      ((t1 -. t0) /. float_of_int (10 * nm) *. 1e9) r
  in
  timem "TIME Swiss ident miss" (fun () ->
    let s = ref 0 in
    for _ = 1 to 10 do
      Array.iter (fun k -> if SwissIdent.mem ti k then incr s) misses
    done; !s);
  timem "TIME Swiss mixed miss" (fun () ->
    let s = ref 0 in
    for _ = 1 to 10 do
      Array.iter (fun k -> if SwissMixed.mem tm k then incr s) misses
    done; !s)

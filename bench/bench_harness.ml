(* Shared benchmark harness for bench.ml (portable tables) and
   bench_simd.ml (per-architecture SIMD instantiation). *)

let now = Unix.gettimeofday
let repeats = 5

let time_ns_per_op ~n f =
  let best = ref infinity in
  for _ = 1 to repeats do
    let t0 = now () in
    f ();
    let dt = now () -. t0 in
    if dt < !best then best := dt
  done;
  !best *. 1e9 /. float_of_int n

module type TABLE = sig
  type key
  type 'a t

  val create : int -> 'a t
  val add : 'a t -> key -> 'a -> unit
  val replace : 'a t -> key -> 'a -> unit
  val find_opt : 'a t -> key -> 'a option
  val mem : 'a t -> key -> bool
  val remove : 'a t -> key -> unit
  val iter : (key -> 'a -> unit) -> 'a t -> unit
  val length : 'a t -> int
end

let shuffle st a =
  let n = Array.length a in
  for i = n - 1 downto 1 do
    let j = Random.State.int st (i + 1) in
    let tmp = a.(i) in
    a.(i) <- a.(j);
    a.(j) <- tmp
  done

let sink = ref 0

(* BENCH_ONLY: comma-separated row-name prefixes; rows not matching are
   skipped, so families can run in separate processes (thermal
   fairness). Empty/unset = run everything. *)
let want name =
  match Sys.getenv_opt "BENCH_ONLY" with
  | None | Some "" -> true
  | Some s ->
    List.exists
      (fun p ->
        String.length p > 0
        && String.length name >= String.length p
        && String.sub name 0 (String.length p) = p)
      (String.split_on_char ',' s)

module Run (T : TABLE) = struct
  let run ~name ~(keys : T.key array) ~(miss : T.key array) =
    if want name then begin
      let n = Array.length keys in
      let line label v =
        Printf.printf "%-24s %-18s %10.1f ns/op\n%!" name label v
      in

      (* insert (with growth, small initial size) *)
      line "insert(grow)"
        (time_ns_per_op ~n (fun () ->
             let t = T.create 16 in
             for i = 0 to n - 1 do
               T.add t (Array.unsafe_get keys i) i
             done;
             sink := !sink + T.length t));

      (* pre-populated table for probe benchmarks *)
      let t = T.create n in
      Array.iteri (fun i k -> T.add t k i) keys;

      line "find hit"
        (time_ns_per_op ~n (fun () ->
             let acc = ref 0 in
             for i = 0 to n - 1 do
               match T.find_opt t (Array.unsafe_get keys i) with
               | Some v -> acc := !acc + v
               | None -> assert false
             done;
             sink := !sink + !acc));

      line "find miss"
        (time_ns_per_op ~n (fun () ->
             let acc = ref 0 in
             for i = 0 to n - 1 do
               match T.find_opt t (Array.unsafe_get miss i) with
               | Some _ -> assert false
               | None -> incr acc
             done;
             sink := !sink + !acc));

      line "mem 50/50"
        (time_ns_per_op ~n (fun () ->
             let acc = ref 0 in
             for i = 0 to n - 1 do
               let k =
                 if i land 1 = 0 then Array.unsafe_get keys i
                 else Array.unsafe_get miss i
               in
               if T.mem t k then incr acc
             done;
             sink := !sink + !acc));

      line "replace existing"
        (time_ns_per_op ~n (fun () ->
             for i = 0 to n - 1 do
               T.replace t (Array.unsafe_get keys i) i
             done));

      line "iter"
        (time_ns_per_op ~n (fun () ->
             let acc = ref 0 in
             T.iter (fun _ v -> acc := !acc + v) t;
             sink := !sink + !acc));

      (* churn: remove half, re-add (exercises tombstones) *)
      line "churn rm/add half"
        (time_ns_per_op ~n (fun () ->
             let h = n / 2 in
             for i = 0 to h - 1 do
               T.remove t (Array.unsafe_get keys i)
             done;
             for i = 0 to h - 1 do
               T.add t (Array.unsafe_get keys i) i
             done))
    end
end

let sizes_of_argv () =
  match Array.to_list Sys.argv with
  | _ :: rest when rest <> [] -> List.map int_of_string rest
  | _ -> [ 1_000; 100_000; 1_000_000 ]

let with_keys ~sizes f =
  let st = Random.State.make [| 42 |] in
  List.iter
    (fun n ->
      Printf.printf "\n=== N = %d ===\n%!" n;
      let int_keys = Array.init n (fun i -> i) in
      let int_miss = Array.init n (fun i -> n + i) in
      shuffle st int_keys;
      shuffle st int_miss;
      let str_keys = Array.map string_of_int int_keys in
      let str_miss = Array.map string_of_int int_miss in
      f ~int_keys ~int_miss ~str_keys ~str_miss)
    sizes;
  Printf.printf "\n(sink=%d)\n" !sink

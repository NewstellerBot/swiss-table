(* Swiss (portable SWAR) vs Stdlib.Hashtbl micro-benchmarks.
   Run: dune exec bench/bench.exe [-- sizes...]   (defaults: 1000 100000 1000000)
   BENCH_ONLY=<row-prefix,...> filters families (thermal fairness).
   SIMD instantiations are benchmarked by bench_simd.exe. *)

open Bench_harness

module SwissInt = struct
  type key = int
  type 'a t = (int, 'a) Swiss.t

  let create n = Swiss.create ~random:false n
  let add = Swiss.add
  let replace = Swiss.replace
  let find_opt = Swiss.find_opt
  let mem = Swiss.mem
  let remove = Swiss.remove
  let iter = Swiss.iter
  let length = Swiss.length
end

module HashtblInt = struct
  type key = int
  type 'a t = (int, 'a) Hashtbl.t

  let create n = Hashtbl.create ~random:false n
  let add = Hashtbl.add
  let replace = Hashtbl.replace
  let find_opt = Hashtbl.find_opt
  let mem = Hashtbl.mem
  let remove = Hashtbl.remove
  let iter = Hashtbl.iter
  let length = Hashtbl.length
end

module IntH = struct
  type t = int

  let equal = Int.equal
  let hash x = Hashtbl.hash x
end

module SwissMakeInt = struct
  include Swiss.Make (IntH)

  type key = int
end

module HashtblMakeInt = struct
  include Hashtbl.Make (IntH)

  type key = int
end

module SwissStr = struct
  type key = string
  type 'a t = (string, 'a) Swiss.t

  let create n = Swiss.create ~random:false n
  let add = Swiss.add
  let replace = Swiss.replace
  let find_opt = Swiss.find_opt
  let mem = Swiss.mem
  let remove = Swiss.remove
  let iter = Swiss.iter
  let length = Swiss.length
end

module HashtblStr = struct
  type key = string
  type 'a t = (string, 'a) Hashtbl.t

  let create n = Hashtbl.create ~random:false n
  let add = Hashtbl.add
  let replace = Hashtbl.replace
  let find_opt = Hashtbl.find_opt
  let mem = Hashtbl.mem
  let remove = Hashtbl.remove
  let iter = Hashtbl.iter
  let length = Hashtbl.length
end

let () =
  with_keys ~sizes:(sizes_of_argv ())
    (fun ~int_keys ~int_miss ~str_keys ~str_miss ->
      let module R1 = Run (SwissInt) in
      let module R2 = Run (HashtblInt) in
      let module R3 = Run (SwissMakeInt) in
      let module R4 = Run (HashtblMakeInt) in
      let module R5 = Run (SwissStr) in
      let module R6 = Run (HashtblStr) in
      R1.run ~name:"Swiss/int" ~keys:int_keys ~miss:int_miss;
      R2.run ~name:"Hashtbl/int" ~keys:int_keys ~miss:int_miss;
      R3.run ~name:"Swiss.Make/int" ~keys:int_keys ~miss:int_miss;
      R4.run ~name:"Hashtbl.Make/int" ~keys:int_keys ~miss:int_miss;
      R5.run ~name:"Swiss/string" ~keys:str_keys ~miss:str_miss;
      R6.run ~name:"Hashtbl/string" ~keys:str_keys ~miss:str_miss)

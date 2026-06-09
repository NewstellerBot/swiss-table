(* Body of bench_simd: a prelude defines [module Simd] (the per-arch
   SIMD Swiss instantiation) and [simd_label]. *)

open Bench_harness

module SimdInt = struct
  type key = int
  type 'a t = (int, 'a) Simd.t

  let create n = Simd.create ~random:false n
  let add = Simd.add
  let replace = Simd.replace
  let find_opt = Simd.find_opt
  let mem = Simd.mem
  let remove = Simd.remove
  let iter = Simd.iter
  let length = Simd.length
end

module IntH = struct
  type t = int

  let equal = Int.equal
  let hash x = Hashtbl.hash x
end

module SimdMakeInt = struct
  include Simd.Make (IntH)

  type key = int
end

module SimdStr = struct
  type key = string
  type 'a t = (string, 'a) Simd.t

  let create n = Simd.create ~random:false n
  let add = Simd.add
  let replace = Simd.replace
  let find_opt = Simd.find_opt
  let mem = Simd.mem
  let remove = Simd.remove
  let iter = Simd.iter
  let length = Simd.length
end

let () =
  with_keys ~sizes:(sizes_of_argv ())
    (fun ~int_keys ~int_miss ~str_keys ~str_miss ->
      let module R1 = Run (SimdInt) in
      let module R2 = Run (SimdMakeInt) in
      let module R3 = Run (SimdStr) in
      R1.run ~name:(simd_label ^ "/int") ~keys:int_keys ~miss:int_miss;
      R2.run ~name:(simd_label ^ ".Make/int") ~keys:int_keys ~miss:int_miss;
      R3.run ~name:(simd_label ^ "/string") ~keys:str_keys ~miss:str_miss)

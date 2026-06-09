(* REVIEW PROBE (temporary): deterministic multi-purge churn with an
   oracle, to measure how often the in-place purge's SWAP branch fires
   (the instrumented engine prints "P" per purge, "S" per swap to
   stderr). Also verifies contents after every purge so a broken swap
   branch would be caught here. *)

let core t = Obj.field (Obj.repr t) 0
let growth_left t = (Obj.obj (Obj.field (Obj.repr t) 2) : int)
let ctrl t = (Obj.obj (Obj.field (core t) 0) : Bytes.t)
let mask t = (Obj.obj (Obj.field (core t) 3) : int)
let buckets t = mask t + 1

let tombstones t =
  let c = ctrl t in
  let n = ref 0 in
  for i = 0 to mask t do
    if Bytes.get c i = '\x80' then incr n
  done;
  !n

let () =
  let t : (int, int) Swiss.t = Swiss.create ~random:false 100 in
  let oracle : (int, int) Hashtbl.t = Hashtbl.create 100 in
  let b0 = buckets t in
  let cap = b0 / 8 * 7 in
  let add k v = Swiss.add t k v; Hashtbl.add oracle k v in
  let remove k = Swiss.remove t k; Hashtbl.remove oracle k in
  for i = 0 to cap - 1 do add i i done;
  for i = 10 to cap - 1 do remove i done;
  let purges = ref 0 in
  let next_add = ref 1000 in
  let next_rm = ref 1000 in
  let items t = (Obj.obj (Obj.field (Obj.repr t) 1) : int) in
  let verify () =
    Hashtbl.iter (fun k v -> assert (Swiss.find_opt t k = Some v)) oracle;
    assert (Swiss.length t = Hashtbl.length oracle)
  in
  for _ = 1 to 400_000 do
    if items t >= (cap / 2) - 2 then begin
      remove !next_rm; incr next_rm
    end
    else begin
      let tb = tombstones t in
      add !next_add 0; incr next_add;
      if tb > 0 && tombstones t = 0 && growth_left t > 0 then begin
        incr purges;
        assert (buckets t = b0);
        verify ()
      end
    end
  done;
  verify ();
  Printf.printf "probe: %d purges observed, table verified\n%!" !purges

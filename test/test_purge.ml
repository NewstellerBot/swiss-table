(* Targeted test for the in-place tombstone purge (generic tables;
   design §3 Resize). Forces the trigger (insert needing an EMPTY slot
   at growth_left = 0 with items + 1 <= capacity/2), then checks:
   - buckets unchanged (no growth happened),
   - a purge actually fired (tombstones dropped to zero),
   - every binding intact, duplicates included,
   - representation invariants (growth_left equation, FULL count,
     dummy discipline),
   - the whole churn is allocation-free for int keys (the purge itself
     must allocate nothing).
   The functor route runs the same scenario for correctness only (it
   uses the copying purge: user hash). *)

(* Obj layout (lib/core/engine_template.inc): t = { c; items;
   growth_left; shadow; nshadow; seed; initial_buckets },
   core = { ctrl; keys; vals; mask }. *)
let core t = Obj.field (Obj.repr t) 0
let items t = (Obj.obj (Obj.field (Obj.repr t) 1) : int)
let growth_left t = (Obj.obj (Obj.field (Obj.repr t) 2) : int)
let ctrl t = (Obj.obj (Obj.field (core t) 0) : Bytes.t)
let keys t = (Obj.obj (Obj.field (core t) 1) : Obj.t array)
let mask t = (Obj.obj (Obj.field (core t) 3) : int)
let buckets t = mask t + 1

let count_ctrl t pred =
  let c = ctrl t in
  let n = ref 0 in
  for i = 0 to mask t do
    if pred (Bytes.get c i) then incr n
  done;
  !n

let tombstones t = count_ctrl t (fun ch -> ch = '\x80')
let fulls t = count_ctrl t (fun ch -> Char.code ch < 0x80)

let check_invariants t =
  let b = buckets t in
  let cap = b / 8 * 7 in
  assert (fulls t = items t);
  assert (growth_left t + items t + tombstones t = cap);
  (* mirrored tail *)
  let c = ctrl t in
  for i = 0 to 7 do
    assert (Bytes.get c (b + i) = Bytes.get c i)
  done;
  (* non-FULL slots hold the dummy (the converse cannot be asserted:
     the int key 0 shares the unit dummy's immediate representation) *)
  let k = keys t in
  let dummy = Obj.repr () in
  for i = 0 to mask t do
    if Char.code (Bytes.get c i) >= 0x80 then assert (k.(i) == dummy)
  done

let () =
  (* --- generic interface: in-place purge path --- *)
  let t : (int, int) Swiss.t = Swiss.create ~random:false 100 in
  let b0 = buckets t in
  let cap = b0 / 8 * 7 in
  (* fill to capacity: growth_left = 0, no tombstones *)
  for i = 0 to cap - 1 do
    Swiss.add t i i
  done;
  assert (buckets t = b0);
  assert (growth_left t = 0);
  (* a duplicate that must survive purges *)
  Swiss.add t 0 42;
  (* mass-remove: groups are full, so erases produce tombstones and
     growth_left stays pinned low *)
  for i = 10 to cap - 1 do
    Swiss.remove t i
  done;
  assert (tombstones t > 0);
  check_invariants t;
  (* Churn fresh keys in and old churn keys out, keeping items below
     cap/2: tombstone reuse absorbs most inserts, but whenever
     growth_left = 0 and an insert's probe hits EMPTY before any
     tombstone, the in-place purge fires (observable as the tombstone
     count dropping to zero with buckets unchanged). The grow branch
     is unreachable because items + 1 <= cap/2 always holds. The
     whole loop is integer-only, so it must be allocation-free —
     including the purges themselves. *)
  let purges = ref 0 in
  let next_add = ref 1000 in
  let next_rm = ref 1000 in
  let before_words = Gc.minor_words () in
  let attempts = ref 0 in
  while !purges = 0 && !attempts < 20_000 do
    incr attempts;
    if items t >= (cap / 2) - 2 then begin
      Swiss.remove t !next_rm;
      incr next_rm
    end
    else begin
      let tb = tombstones t in
      Swiss.add t !next_add 0;
      incr next_add;
      if tb > 0 && tombstones t = 0 then begin
        incr purges;
        assert (buckets t = b0);
        check_invariants t
      end
    end
  done;
  let words = Gc.minor_words () -. before_words in
  assert (!purges > 0);
  assert (buckets t = b0);
  check_invariants t;
  (* original bindings intact, duplicate stack included *)
  assert (Swiss.find_all t 0 = [ 42; 0 ]);
  for i = 1 to 9 do
    assert (Swiss.find_opt t i = Some i)
  done;
  for i = 10 to cap - 1 do
    assert (not (Swiss.mem t i))
  done;
  (* churn keys: removed ones gone, live ones present *)
  for i = 1000 to !next_rm - 1 do
    assert (not (Swiss.mem t i))
  done;
  for i = !next_rm to !next_add - 1 do
    assert (Swiss.mem t i)
  done;
  (* the churn (incl. the purges) must be allocation-free *)
  if words > 64.0 then begin
    Printf.printf "FAIL purge churn allocated %.1f minor words\n" words;
    exit 1
  end;
  Printf.printf "purge[generic]: %d in-place purges, %.1f minor words, OK\n"
    !purges words;

  (* --- functor route (copying purge): correctness only --- *)
  let module M = Swiss.Make (struct
    type t = int

    let equal = Int.equal
    let hash x = Hashtbl.hash x
  end) in
  let m = M.create 100 in
  for i = 0 to cap - 1 do
    M.add m i i
  done;
  M.add m 0 42;
  for i = 10 to cap - 1 do
    M.remove m i
  done;
  for i = 1000 to 1000 + (3 * cap) do
    M.add m i i;
    M.remove m i
  done;
  assert (M.find_all m 0 = [ 42; 0 ]);
  for i = 1 to 9 do
    assert (M.find_opt m i = Some i)
  done;
  print_endline "purge[functor]: OK"

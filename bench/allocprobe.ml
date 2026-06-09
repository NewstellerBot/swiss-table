(* Allocation probe: minor words per operation for Swiss vs stdlib. *)

module SwissInt = Swiss.MakeSeeded (struct
  type t = int
  let equal (a : int) b = a = b
  let seeded_hash seed (x : int) = Hashtbl.seeded_hash seed x
end)

module StdInt = Hashtbl.MakeSeeded (struct
  type t = int
  let equal (a : int) b = a = b
  let seeded_hash seed (x : int) = Hashtbl.seeded_hash seed x
end)

let n = 200_000

let measure name f =
  (* warmup *)
  f ();
  let w0 = Gc.minor_words () in
  f ();
  let w1 = Gc.minor_words () in
  Printf.printf "%-32s %8.2f minor words/op\n%!" name ((w1 -. w0) /. float n)

let () =
  let st = SwissInt.create 2048 in
  for i = 0 to 1023 do SwissInt.replace st i i done;
  let ht = StdInt.create 2048 in
  for i = 0 to 1023 do StdInt.replace ht i i done;
  let gt : (int, int) Swiss.t = Swiss.create 2048 in
  for i = 0 to 1023 do Swiss.replace gt i i done;

  let sink = ref 0 in

  measure "Swiss.MakeSeeded mem (hit)" (fun () ->
      for i = 0 to n - 1 do
        if SwissInt.mem st (i land 1023) then incr sink
      done);
  measure "Swiss.MakeSeeded mem (miss)" (fun () ->
      for i = 0 to n - 1 do
        if SwissInt.mem st (100_000 + (i land 1023)) then incr sink
      done);
  measure "Swiss.MakeSeeded find (hit)" (fun () ->
      for i = 0 to n - 1 do
        sink := !sink + SwissInt.find st (i land 1023)
      done);
  measure "Swiss.MakeSeeded find_opt (hit)" (fun () ->
      for i = 0 to n - 1 do
        match SwissInt.find_opt st (i land 1023) with
        | Some v -> sink := !sink + v
        | None -> ()
      done);
  measure "Swiss.MakeSeeded replace (exist)" (fun () ->
      for i = 0 to n - 1 do
        SwissInt.replace st (i land 1023) i
      done);
  measure "Swiss generic mem (hit)" (fun () ->
      for i = 0 to n - 1 do
        if Swiss.mem gt (i land 1023) then incr sink
      done);
  measure "Stdlib.MakeSeeded mem (hit)" (fun () ->
      for i = 0 to n - 1 do
        if StdInt.mem ht (i land 1023) then incr sink
      done);
  measure "Stdlib.MakeSeeded find (hit)" (fun () ->
      for i = 0 to n - 1 do
        sink := !sink + StdInt.find ht (i land 1023)
      done);
  measure "Stdlib.MakeSeeded replace (ex)" (fun () ->
      for i = 0 to n - 1 do
        StdInt.replace ht (i land 1023) i
      done);
  measure "bare seeded_hash" (fun () ->
      for i = 0 to n - 1 do
        sink := !sink + Hashtbl.seeded_hash 42 (i land 1023)
      done);
  Printf.printf "sink=%d\n" !sink

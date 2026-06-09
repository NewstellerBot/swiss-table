(* test_group_sse.ml — standalone differential selftest for
   lib_sse/group_sse.inc (the SSE2/amd64 16-wide GROUP module).

   This file is the test BODY: it references a module [G] that is the
   group implementation. The runnable program is produced by pasting
   group_sse.inc into a [module G = struct ... end] wrapper ABOVE this
   file — the same same-unit pasting the dune rules use for the real
   library, so inlining behaves identically.

   CI BUILD + RUN (single command, from swiss/lib_sse/, on an x86_64
   host with the OxCaml native compiler on PATH):

     { echo 'open! Stdlib'; echo 'module G = struct'; cat group_sse.inc; \
       echo 'end'; cat test_group_sse.ml; } > test_group_sse_main.ml \
     && ocamlopt -O3 -extension simd sse_stubs.c test_group_sse_main.ml \
          -o test_group_sse_main \
     && ./test_group_sse_main

   (-extension simd is redundant on a default-configured oxcaml but
   harmless.) On success prints "group_sse selftest OK" and exits 0;
   otherwise prints the first failures and exits 1.

   What is checked (against independent scalar byte-loop references):
     1. Mask helpers EXHAUSTIVELY over all 65536 dense-16 masks
        (including 0): trailing_zero_count, leading_zero_count, and for
        m <> 0 lowest_idx / clear_lowest.
     2. Directed adversarial ctrl windows at many (unaligned) positions:
        all-16 uniform windows for EVERY byte value 0..255; all-FULL /
        all-EMPTY / all-DELETED; the tag planted at every one of the 16
        positions over EMPTY/DELETED/FULL fills; tags 0x00, 0x2A, 0x7F;
        EMPTY and DELETED planted at every position; alternating and
        boundary-value (0x7F/0x80/0x81/0xFE/0xFF/0x00) patterns.
     3. >= 1,000,000 randomized windows (deterministic seed), four byte
        regimes (uniform 0..255, valid-ctrl-only, match-dense,
        empty-dense), random unaligned positions and tags.
     4. Allocation: a 1M-iteration hot loop over all GROUP ops must
        allocate 0.00 minor words/op (Gc.minor_words delta).

   Every probe_find/probe_insert/match_* result is compared for exact
   equality with the reference masks. The GROUP contract only requires
   the probe empty_mask to be nonzero-iff (and allows match_mask false
   positives); group_sse.inc documents strictly positional, exact
   masks, so this test locks the stronger property on purpose — relax
   it if a future variant legitimately weakens a component. *)

(* ------------------------------------------------------------------ *)
(* Failure accounting                                                  *)
(* ------------------------------------------------------------------ *)

let failures = ref 0
let max_print = 25

let failf msg =
  incr failures;
  if !failures <= max_print then print_string msg

let window_hex ctrl pos =
  String.concat ""
    (List.init 16 (fun i ->
         Printf.sprintf "%02x" (Char.code (Bytes.get ctrl (pos + i)))))

(* ------------------------------------------------------------------ *)
(* Scalar reference implementation of the GROUP functions              *)
(* ------------------------------------------------------------------ *)

let byte b i = Char.code (Bytes.get b i)

(* dense-16 mask of bytes equal to [tag] *)
let ref_match ctrl pos tag =
  let m = ref 0 in
  for i = 0 to 15 do
    if byte ctrl (pos + i) = tag then m := !m lor (1 lsl i)
  done;
  !m

(* dense-16 mask of EMPTY (0xFF) bytes *)
let ref_empty ctrl pos =
  let m = ref 0 in
  for i = 0 to 15 do
    if byte ctrl (pos + i) = 0xff then m := !m lor (1 lsl i)
  done;
  !m

(* dense-16 mask of EMPTY-or-DELETED bytes (top bit set) *)
let ref_med ctrl pos =
  let m = ref 0 in
  for i = 0 to 15 do
    if byte ctrl (pos + i) >= 0x80 then m := !m lor (1 lsl i)
  done;
  !m

let ref_lowest_idx m =
  let rec go i = if (m lsr i) land 1 = 1 then i else go (i + 1) in
  go 0

let ref_highest_idx m =
  let rec go i = if (m lsr i) land 1 = 1 then i else go (i - 1) in
  go 15

let ref_tzc m = if m = 0 then 16 else ref_lowest_idx m
let ref_lzc m = if m = 0 then 16 else 15 - ref_highest_idx m
let ref_clear_lowest m = if m = 0 then 0 else m lxor (1 lsl ref_lowest_idx m)

(* ------------------------------------------------------------------ *)
(* 1. Exhaustive mask-helper checks (all 65536 masks, incl. 0)         *)
(* ------------------------------------------------------------------ *)

let () =
  if G.width <> 16 then
    failf (Printf.sprintf "FAIL width: %d <> 16\n" G.width);
  for m = 0 to 0xffff do
    let t = G.trailing_zero_count m and t' = ref_tzc m in
    if t <> t' then
      failf (Printf.sprintf "FAIL tzc %#x: %d <> %d\n" m t t');
    let l = G.leading_zero_count m and l' = ref_lzc m in
    if l <> l' then
      failf (Printf.sprintf "FAIL lzc %#x: %d <> %d\n" m l l');
    if m <> 0 then begin
      let i = G.lowest_idx m and i' = ref_lowest_idx m in
      if i <> i' then
        failf (Printf.sprintf "FAIL lowest_idx %#x: %d <> %d\n" m i i');
      let c = G.clear_lowest m and c' = ref_clear_lowest m in
      if c <> c' then
        failf (Printf.sprintf "FAIL clear_lowest %#x: %#x <> %#x\n" m c c')
    end
  done;
  if G.clear_lowest 0 <> 0 then
    failf (Printf.sprintf "FAIL clear_lowest 0: %#x <> 0\n" (G.clear_lowest 0));
  Printf.printf "helpers: 65536/65536 masks OK (failures so far: %d)\n%!"
    !failures

(* ------------------------------------------------------------------ *)
(* Window checker: every GROUP op vs the reference                     *)
(* ------------------------------------------------------------------ *)

let windows_checked = ref 0

let check_window ctrl pos tag =
  incr windows_checked;
  let em = ref_match ctrl pos tag in
  let ee = ref_empty ctrl pos in
  let ed = ref_med ctrl pos in
  let ctx () =
    Printf.sprintf "  window=%s pos=%d tag=%#x\n" (window_hex ctrl pos) pos tag
  in
  let #(m1, e1) = G.probe_find ctrl pos tag in
  if m1 <> em then
    failf (Printf.sprintf "FAIL probe_find match: %#x <> %#x\n%s" m1 em (ctx ()));
  if e1 <> ee then
    failf (Printf.sprintf "FAIL probe_find empty: %#x <> %#x\n%s" e1 ee (ctx ()));
  let #(m2, e2, d2) = G.probe_insert ctrl pos tag in
  if m2 <> em then
    failf (Printf.sprintf "FAIL probe_insert match: %#x <> %#x\n%s" m2 em (ctx ()));
  if e2 <> ee then
    failf (Printf.sprintf "FAIL probe_insert empty: %#x <> %#x\n%s" e2 ee (ctx ()));
  if d2 <> ed then
    failf (Printf.sprintf "FAIL probe_insert med: %#x <> %#x\n%s" d2 ed (ctx ()));
  let me = G.match_empty ctrl pos in
  if me <> ee then
    failf (Printf.sprintf "FAIL match_empty: %#x <> %#x\n%s" me ee (ctx ()));
  let md = G.match_empty_or_deleted ctrl pos in
  if md <> ed then
    failf (Printf.sprintf "FAIL match_empty_or_deleted: %#x <> %#x\n%s" md ed
             (ctx ()));
  (* iteration consistency over the returned match mask: lowest-first,
     strictly increasing byte offsets, each a true match *)
  let mm = ref m1 in
  let prev = ref (-1) in
  let ok = ref true in
  while !mm <> 0 && !ok do
    let idx = G.lowest_idx !mm in
    if idx <= !prev || idx > 15 || byte ctrl (pos + idx) <> tag then begin
      ok := false;
      failf
        (Printf.sprintf "FAIL mask iteration: idx=%d prev=%d m=%#x\n%s" idx
           !prev m1 (ctx ()))
    end;
    prev := idx;
    mm := G.clear_lowest !mm
  done

(* ------------------------------------------------------------------ *)
(* 2. Directed adversarial windows                                     *)
(* ------------------------------------------------------------------ *)

let buf_len = 256
let buf = Bytes.create buf_len

(* positions chosen to exercise every load alignment mod 16, plus the
   ends of the buffer *)
let positions = [| 0; 1; 2; 3; 5; 7; 8; 11; 13; 15; 16; 31; 100; 240 |]

let set_window pos f poison =
  Bytes.fill buf 0 buf_len (Char.chr poison);
  for i = 0 to 15 do
    Bytes.set buf (pos + i) (Char.chr (f i land 0xff))
  done

let () =
  Array.iter
    (fun pos ->
      (* uniform windows: every byte value, incl. specials and invalid
         ctrl values (the ops are mechanically defined for all bytes) *)
      for b = 0 to 255 do
        set_window pos (fun _ -> b) (if b land 1 = 0 then 0xaa else 0x11);
        check_window buf pos 0x00;
        check_window buf pos 0x7f;
        check_window buf pos (b land 0x7f)
      done;
      (* the tag planted at every position, over each fill; and probes
         for an absent tag on the same windows *)
      List.iter
        (fun tag ->
          List.iter
            (fun fill ->
              if fill <> tag then
                for i = 0 to 15 do
                  set_window pos (fun j -> if j = i then tag else fill) 0x33;
                  check_window buf pos tag;
                  check_window buf pos ((tag + 1) land 0x7f)
                done)
            [ 0xff; 0x80; 0x00; 0x7f; 0x55 ])
        [ 0x00; 0x2a; 0x7f ];
      (* EMPTY / DELETED planted at every position over a FULL fill *)
      for i = 0 to 15 do
        set_window pos (fun j -> if j = i then 0xff else 0x12) 0x44;
        check_window buf pos 0x12;
        set_window pos (fun j -> if j = i then 0x80 else 0x12) 0x44;
        check_window buf pos 0x12
      done;
      (* alternating and boundary-value patterns *)
      set_window pos (fun i -> if i land 1 = 0 then 0xff else 0x80) 0x55;
      check_window buf pos 0x00;
      check_window buf pos 0x7f;
      set_window pos (fun i -> if i land 1 = 0 then 0x2a else 0xff) 0x55;
      check_window buf pos 0x2a;
      set_window pos (fun i -> i) 0x66;
      check_window buf pos 0x00;
      check_window buf pos 0x0f;
      set_window pos (fun i -> 0x70 + i) 0x66;
      check_window buf pos 0x7f;
      check_window buf pos 0x70;
      set_window pos
        (fun i -> [| 0x7f; 0x80; 0x81; 0xfe; 0xff; 0x00 |].(i mod 6))
        0x77;
      check_window buf pos 0x7f;
      check_window buf pos 0x00)
    positions;
  Printf.printf "directed: %d windows OK (failures so far: %d)\n%!"
    !windows_checked !failures

(* ------------------------------------------------------------------ *)
(* 3. Randomized windows (deterministic)                               *)
(* ------------------------------------------------------------------ *)

let n_random = 1_200_000

let () =
  let st = Random.State.make [| 0x5eed; 0xca11; 42 |] in
  for it = 1 to n_random do
    let pos = Random.State.int st (buf_len - 16) in
    let tag = Random.State.int st 0x80 in
    let regime = it land 3 in
    for i = 0 to 15 do
      let b =
        match regime with
        | 0 -> Random.State.int st 256
        | 1 -> (
          (* valid ctrl bytes only *)
          match Random.State.int st 4 with
          | 0 -> 0xff
          | 1 -> 0x80
          | _ -> Random.State.int st 0x80)
        | 2 ->
          (* match-dense *)
          if Random.State.bool st then tag else Random.State.int st 256
        | _ ->
          (* empty-dense with sparse FULL *)
          if Random.State.int st 8 = 0 then Random.State.int st 0x80 else 0xff
      in
      Bytes.set buf (pos + i) (Char.chr b)
    done;
    check_window buf pos tag;
    if it land 63 = 0 then check_window buf pos ((tag + 1) land 0x7f)
  done;
  Printf.printf "randomized: %d windows total OK (failures so far: %d)\n%!"
    !windows_checked !failures

(* ------------------------------------------------------------------ *)
(* 4. Allocation check: 0.00 minor words/op expected                   *)
(* ------------------------------------------------------------------ *)

let () =
  let ctrl = Bytes.create 64 in
  for i = 0 to 63 do
    Bytes.set ctrl i
      (Char.chr
         (match i land 7 with
         | 0 -> 0xff
         | 1 -> 0x80
         | k -> (i * 11 + k) land 0x7f))
  done;
  let acc = ref 0 in
  let iters = 1_000_000 in
  let run n =
    for k = 1 to n do
      let pos = k * 7 land 47 in
      let tag = k * 13 land 0x7f in
      let #(m, e) = G.probe_find ctrl pos tag in
      let #(m2, e2, d2) = G.probe_insert ctrl pos tag in
      let me = G.match_empty ctrl pos in
      let md = G.match_empty_or_deleted ctrl pos in
      acc :=
        !acc lxor m lxor e lxor m2 lxor e2 lxor d2 lxor me lxor md
        lxor G.trailing_zero_count m
        lxor G.leading_zero_count m;
      if m2 <> 0 then acc := !acc + G.lowest_idx m2 + G.clear_lowest m2
    done
  in
  run 10_000 (* warmup *);
  let w0 = Gc.minor_words () in
  run iters;
  let w1 = Gc.minor_words () in
  ignore (Sys.opaque_identity !acc);
  let per_op = (w1 -. w0) /. float_of_int iters in
  Printf.printf "alloc: %.2f minor words/op (delta %.0f words / %d iters)\n%!"
    per_op (w1 -. w0) iters;
  if not (per_op < 0.001) then
    failf
      (Printf.sprintf "FAIL alloc: %f minor words/op (expected 0.00)\n" per_op)

(* ------------------------------------------------------------------ *)
(* Verdict                                                             *)
(* ------------------------------------------------------------------ *)

let () =
  if !windows_checked < 1_000_000 then
    failf
      (Printf.sprintf "FAIL coverage: only %d windows checked\n"
         !windows_checked);
  if !failures = 0 then begin
    print_endline "group_sse selftest OK";
    exit 0
  end
  else begin
    Printf.printf "group_sse selftest: %d FAILURES (%d printed)\n" !failures
      (min !failures max_print);
    exit 1
  end

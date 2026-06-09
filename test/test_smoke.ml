let () =
  (* basics *)
  let t = Swiss.create 10 in
  for i = 0 to 999 do
    Swiss.add t i (i * 2)
  done;
  assert (Swiss.length t = 1000);
  for i = 0 to 999 do
    assert (Swiss.find t i = i * 2);
    assert (Swiss.find_opt t i = Some (i * 2));
    assert (Swiss.mem t i)
  done;
  assert (not (Swiss.mem t 1000));
  assert (Swiss.find_opt t (-1) = None);
  (match Swiss.find t 5000 with
  | exception Not_found -> ()
  | _ -> assert false);

  (* multi-binding semantics *)
  let d = Swiss.create 4 in
  Swiss.add d "k" 1;
  Swiss.add d "k" 2;
  Swiss.add d "k" 3;
  assert (Swiss.length d = 3);
  assert (Swiss.find d "k" = 3);
  assert (Swiss.find_all d "k" = [ 3; 2; 1 ]);
  Swiss.remove d "k";
  assert (Swiss.find d "k" = 2);
  assert (Swiss.find_all d "k" = [ 2; 1 ]);
  Swiss.replace d "k" 9;
  assert (Swiss.find_all d "k" = [ 9; 1 ]);
  Swiss.remove d "k";
  Swiss.remove d "k";
  assert (not (Swiss.mem d "k"));
  assert (Swiss.length d = 0);

  (* removal / tombstones / reuse *)
  let r = Swiss.create 8 in
  for i = 0 to 99 do Swiss.add r i i done;
  for i = 0 to 99 do if i mod 2 = 0 then Swiss.remove r i done;
  assert (Swiss.length r = 50);
  for i = 0 to 99 do
    assert (Swiss.mem r i = (i mod 2 = 1))
  done;
  for i = 100 to 199 do Swiss.add r i i done;
  assert (Swiss.length r = 150);

  (* iter/fold count every binding *)
  let n = ref 0 in
  Swiss.iter (fun _ _ -> incr n) t;
  assert (!n = 1000);
  assert (Swiss.fold (fun _ _ acc -> acc + 1) t 0 = 1000);

  (* copy independence *)
  let c = Swiss.copy d in
  Swiss.add d "x" 1;
  assert (Swiss.length c = 0 && Swiss.length d = 1);

  (* clear/reset *)
  Swiss.clear t;
  assert (Swiss.length t = 0 && not (Swiss.mem t 1));
  Swiss.reset t;
  assert (Swiss.length t = 0);

  (* filter_map_inplace *)
  let f = Swiss.create 4 in
  for i = 0 to 9 do Swiss.add f i i done;
  Swiss.add f 0 100;
  (* key 0 now has bindings [100; 0] *)
  Swiss.filter_map_inplace
    (fun _ v -> if v mod 2 = 0 then Some (v + 1) else None)
    f;
  (* evens survive incremented, odds dropped; key 0: 100 -> 101, 0 -> 1 *)
  assert (Swiss.find_all f 0 = [ 101; 1 ]);
  assert (not (Swiss.mem f 1));
  assert (Swiss.find f 2 = 3);

  (* seqs *)
  let s = Swiss.create 4 in
  Swiss.add_seq s (List.to_seq [ (1, "a"); (1, "b"); (2, "c") ]);
  assert (Swiss.find_all s 1 = [ "b"; "a" ]);
  let s2 = Swiss.of_seq (List.to_seq [ (1, "a"); (1, "b") ]) in
  assert (Swiss.find_all s2 1 = [ "b" ]);
  assert (List.length (List.of_seq (Swiss.to_seq s)) = 3);

  (* stats *)
  let st = Swiss.stats s in
  assert (st.Swiss.num_bindings = 3);
  assert (st.Swiss.max_bucket_length = 2);

  (* rebuild *)
  let rb = Swiss.rebuild ~random:false s in
  assert (Swiss.find_all rb 1 = [ "b"; "a" ]);
  assert (Swiss.length rb = 3);

  (* functorial *)
  let module H = struct
    type t = int

    let equal = Int.equal
    let hash x = Hashtbl.hash x
  end in
  let module M = Swiss.Make (H) in
  let m = M.create 4 in
  for i = 0 to 99 do M.add m i (string_of_int i) done;
  assert (M.length m = 100);
  assert (M.find m 42 = "42");
  M.remove m 42;
  assert (not (M.mem m 42));

  (* nan keys: generic equality is compare-based *)
  let nt = Swiss.create 4 in
  Swiss.add nt nan "nan";
  assert (Swiss.mem nt nan);
  assert (Swiss.find nt nan = "nan");

  print_endline "smoke OK"

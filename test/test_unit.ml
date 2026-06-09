(* Targeted unit + regression tests for Swiss (Swiss-table Hashtbl reimpl).

   Expected behavior is derived from docs/research/api.md and verified against
   the real Stdlib.Hashtbl as oracle (see comments per group), NOT from the
   implementation. Documented deviations (docs/design.md section 1) are not
   tested for stdlib parity (iteration order across keys, stats representation
   values, cyclic/closure keys with add, ...).

   Each design-review (docs/design-review.md) SERIOUS/MINOR finding gets a
   regression test here.

   Prints one line per test group; exits nonzero on failure. *)

let () = Printexc.record_backtrace true

let failures = ref 0

let group name f =
  match f () with
  | () -> Printf.printf "OK   %s\n%!" name
  | exception e ->
    incr failures;
    Printf.printf "FAIL %s: %s\n%s%!" name (Printexc.to_string e)
      (Printexc.get_backtrace ())

let check b msg = if not b then failwith msg

let check_eq_int ~msg got expected =
  if got <> expected then
    failwith (Printf.sprintf "%s: got %d, expected %d" msg got expected)

let show_ints l = "[" ^ String.concat ";" (List.map string_of_int l) ^ "]"

let check_ilist ~msg got expected =
  if got <> expected then
    failwith
      (Printf.sprintf "%s: got %s, expected %s" msg (show_ints got)
         (show_ints expected))

let nbuckets t = (Swiss.stats t).Swiss.num_buckets

(* ------------------------------------------------------------------ *)
(* Invariant checker (the representation is private, so we walk it with
   Obj). Record fields, in declaration order (docs/design.md section 2):
     0: core   = block of 4: (ctrl : Bytes.t, keys : Obj.t array,
                              vals : Obj.t array, mask : int)
     1: items          (number of FULL slots = distinct live keys)
     2: growth_left
     3: shadow         (('a, ('a*'b) list) t option)
     4: nshadow
     5: seed
     6: initial_buckets
   ctrl encoding: EMPTY = 0xFF, DELETED = 0x80, FULL = h2 (top bit clear).
   Capacity = 7/8 * buckets.                                            *)

let dummy = Obj.repr ()
let is_full_byte c = Char.code c land 0x80 = 0

type raw = {
  ctrl : Bytes.t;
  keys : Obj.t array;
  vals : Obj.t array;
  mask : int;
  items : int;
  growth_left : int;
  shadow : Obj.t; (* the option, unparsed *)
  nshadow : int;
  initial_buckets : int;
}

let raw_of_table (o : Obj.t) : raw =
  check (Obj.is_block o) "inv: table is not a block";
  check (Obj.size o = 7)
    (Printf.sprintf "inv: table has %d fields, expected 7" (Obj.size o));
  let c = Obj.field o 0 in
  check (Obj.is_block c && Obj.size c = 4) "inv: core is not a 4-field block";
  check (Obj.tag (Obj.field c 0) = Obj.string_tag) "inv: core.ctrl is not bytes";
  check
    (Obj.is_block (Obj.field c 1) && Obj.tag (Obj.field c 1) = 0)
    "inv: core.keys is not an array";
  check
    (Obj.is_block (Obj.field c 2) && Obj.tag (Obj.field c 2) = 0)
    "inv: core.vals is not an array";
  check (Obj.is_int (Obj.field c 3)) "inv: core.mask is not an int";
  {
    ctrl = Obj.obj (Obj.field c 0);
    keys = Obj.obj (Obj.field c 1);
    vals = Obj.obj (Obj.field c 2);
    mask = Obj.obj (Obj.field c 3);
    items = Obj.obj (Obj.field o 1);
    growth_left = Obj.obj (Obj.field o 2);
    shadow = Obj.field o 3;
    nshadow = Obj.obj (Obj.field o 4);
    initial_buckets = Obj.obj (Obj.field o 6);
  }

(* length of an ('a * 'b) list viewed as Obj.t *)
let stack_length (o : Obj.t) : int =
  let rec go o n =
    if Obj.is_int o then begin
      check ((Obj.obj o : int) = 0) "inv: malformed list terminator";
      n
    end
    else begin
      check (Obj.tag o = 0 && Obj.size o = 2) "inv: malformed stack cons cell";
      let pair = Obj.field o 0 in
      check (Obj.is_block pair && Obj.size pair = 2) "inv: stack entry not a pair";
      go (Obj.field o 1) (n + 1)
    end
  in
  go o 0

(* Structural checks of one table; returns the raw view. When
   [boxed_keys] is set, additionally asserts FULL slots do not hold the
   dummy (only valid when keys can never be the immediate 0/()). *)
let rec check_table ~boxed_keys ~is_shadow (o : Obj.t) : raw =
  let r = raw_of_table o in
  let buckets = r.mask + 1 in
  check (buckets >= 8) "inv: buckets < 8";
  check (buckets land (buckets - 1) = 0) "inv: buckets not a power of two";
  check
    (r.initial_buckets >= 8
    && r.initial_buckets land (r.initial_buckets - 1) = 0)
    "inv: initial_buckets not a power of two >= 8";
  check (Bytes.length r.ctrl = buckets + 8) "inv: ctrl length <> buckets + 8";
  check (Array.length r.keys = buckets) "inv: keys length <> buckets";
  check (Array.length r.vals = buckets) "inv: vals length <> buckets";
  (* ctrl tail mirrors the first group: tail byte buckets+j mirrors ctrl[j].
     The very last tail byte may legitimately never have been written (then it
     is still EMPTY). *)
  for j = 0 to 6 do
    check
      (Bytes.get r.ctrl (buckets + j) = Bytes.get r.ctrl j)
      (Printf.sprintf "inv: ctrl tail byte %d does not mirror ctrl[%d]" j j)
  done;
  let t7 = Bytes.get r.ctrl (buckets + 7) in
  check
    (t7 = Bytes.get r.ctrl 7 || Char.code t7 = 0xFF)
    "inv: ctrl tail byte 7 neither mirrors ctrl[7] nor EMPTY";
  let full = ref 0 and deleted = ref 0 in
  for i = 0 to buckets - 1 do
    let c = Bytes.get r.ctrl i in
    if is_full_byte c then begin
      incr full;
      if boxed_keys then
        check (not (r.keys.(i) == dummy)) "inv: FULL slot holds the dummy key"
    end
    else begin
      let cc = Char.code c in
      check
        (cc = 0x80 || cc = 0xFF)
        (Printf.sprintf "inv: invalid ctrl byte 0x%02x" cc);
      if cc = 0x80 then incr deleted;
      check (r.keys.(i) == dummy) "inv: non-FULL slot key is not the dummy";
      check (r.vals.(i) == dummy) "inv: non-FULL slot val is not the dummy"
    end
  done;
  check_eq_int ~msg:"inv: items <> number of FULL ctrl bytes" r.items !full;
  check_eq_int
    ~msg:"inv: growth_left + items + tombstones <> 7/8 * buckets"
    (r.growth_left + r.items + !deleted)
    (buckets / 8 * 7);
  (* shadow side-table *)
  if Obj.is_int r.shadow then
    check (r.nshadow = 0) "inv: shadow = None but nshadow <> 0"
  else begin
    check (not is_shadow) "inv: shadow table has its own shadow";
    check (r.nshadow > 0) "inv: shadow = Some _ but nshadow = 0";
    check (Obj.size r.shadow = 1) "inv: malformed shadow option";
    let s = check_table ~boxed_keys ~is_shadow:true (Obj.field r.shadow 0) in
    check (s.nshadow = 0) "inv: shadow table has nonzero nshadow";
    let total = ref 0 in
    for i = 0 to s.mask do
      if is_full_byte (Bytes.get s.ctrl i) then begin
        let len = stack_length s.vals.(i) in
        check (len >= 1) "inv: empty shadow stack entry";
        total := !total + len
      end
    done;
    check_eq_int ~msg:"inv: nshadow <> total stacked bindings" r.nshadow !total;
    check (s.items <= r.items) "inv: more shadow entries than live keys"
  end;
  r

(* For functor tables (abstract type): structural checks only. *)
let check_raw_invariants (o : Obj.t) : unit =
  ignore (check_table ~boxed_keys:false ~is_shadow:false o)

(* Full checker for generic tables: structural checks plus "every shadow
   key is present in the flat table" (via the public Swiss.mem). *)
let check_invariants ?(boxed_keys = false) t =
  let r = check_table ~boxed_keys ~is_shadow:false (Obj.repr t) in
  if not (Obj.is_int r.shadow) then begin
    let s = raw_of_table (Obj.field r.shadow 0) in
    for i = 0 to s.mask do
      if is_full_byte (Bytes.get s.ctrl i) then
        check
          (Swiss.mem t (Obj.obj s.keys.(i)))
          "inv: shadow key not present in the flat table"
    done
  end

(* A truly empty table: every ctrl byte EMPTY, full growth_left. Used to
   verify clear wipes tombstones (design-review oxcaml#8 regression). *)
let check_pristine t =
  let r = raw_of_table (Obj.repr t) in
  let buckets = r.mask + 1 in
  for i = 0 to buckets - 1 do
    check
      (Char.code (Bytes.get r.ctrl i) = 0xFF)
      "pristine: ctrl byte not EMPTY (leftover tombstone or entry)"
  done;
  check_eq_int ~msg:"pristine: items" r.items 0;
  check_eq_int ~msg:"pristine: nshadow" r.nshadow 0;
  check_eq_int ~msg:"pristine: growth_left" r.growth_left (buckets / 8 * 7)

(* ------------------------------------------------------------------ *)
(* 1. Resize boundaries (design-review algorithm#3 regression:
      duplicate add / replace at full load must not grow).             *)

let () =
  group "resize-boundaries" (fun () ->
      let t = Swiss.create ~random:false 8 in
      let b0 = nbuckets t in
      let cap = b0 / 8 * 7 in
      for i = 1 to cap do
        Swiss.add t i (i * 3)
      done;
      check_invariants t;
      check_eq_int ~msg:"grew before exceeding capacity" (nbuckets t) b0;
      check_eq_int ~msg:"length at exactly-full" (Swiss.length t) cap;
      Swiss.add t (cap + 1) ((cap + 1) * 3);
      check (nbuckets t > b0) "did not grow past capacity";
      for i = 1 to cap + 1 do
        check_eq_int ~msg:"binding lost across growth" (Swiss.find t i) (i * 3)
      done;
      check_eq_int ~msg:"length after growth" (Swiss.length t) (cap + 1);
      check_invariants t;
      (* duplicate add at exactly-full load: shadow push, must NOT grow *)
      let t = Swiss.create ~random:false 8 in
      let b0 = nbuckets t in
      let cap = b0 / 8 * 7 in
      for i = 1 to cap do
        Swiss.add t i i
      done;
      check_eq_int ~msg:"setup: table grew while filling" (nbuckets t) b0;
      Swiss.add t 1 101;
      check_eq_int ~msg:"duplicate add at full load grew the table"
        (nbuckets t) b0;
      check_ilist ~msg:"duplicate stack" (Swiss.find_all t 1) [ 101; 1 ];
      check_eq_int ~msg:"length counts the duplicate" (Swiss.length t) (cap + 1);
      (* replace of an existing key at full load must not grow either *)
      Swiss.replace t 2 202;
      check_eq_int ~msg:"replace at full load grew the table" (nbuckets t) b0;
      check_eq_int ~msg:"replace value" (Swiss.find t 2) 202;
      check_eq_int ~msg:"replace must not change length" (Swiss.length t)
        (cap + 1);
      check_invariants t)

(* ------------------------------------------------------------------ *)
(* 2. Tombstones: mass remove, re-insert, constant-size churn.         *)

let () =
  group "tombstones" (fun () ->
      let t = Swiss.create ~random:false 8 in
      for i = 0 to 199 do
        Swiss.add t i i
      done;
      for i = 0 to 199 do
        if i mod 3 <> 0 then Swiss.remove t i
      done;
      check_invariants t;
      for i = 0 to 199 do
        check
          (Swiss.mem t i = (i mod 3 = 0))
          (Printf.sprintf "membership wrong for %d after mass remove" i)
      done;
      check_eq_int ~msg:"length after mass remove" (Swiss.length t) 67;
      (* re-insert over the tombstones: no data loss *)
      for i = 0 to 199 do
        if i mod 3 <> 0 then Swiss.add t i (i + 1000)
      done;
      for i = 0 to 199 do
        check_eq_int ~msg:"value wrong after re-insert" (Swiss.find t i)
          (if i mod 3 = 0 then i else i + 1000)
      done;
      check_eq_int ~msg:"length after re-insert" (Swiss.length t) 200;
      check_invariants t;
      (* long add/remove churn at constant size: same-size rehash must keep
         num_buckets constant (no unbounded growth from tombstones) *)
      let t = Swiss.create ~random:false 8 in
      let b0 = nbuckets t in
      for i = 0 to 4 do
        Swiss.add t i i
      done;
      for i = 5 to 10004 do
        Swiss.add t i i;
        Swiss.remove t (i - 5);
        if i mod 500 = 0 then
          check_eq_int ~msg:"buckets grew during constant-size churn"
            (nbuckets t) b0
      done;
      check_eq_int ~msg:"buckets after churn" (nbuckets t) b0;
      check_eq_int ~msg:"length after churn" (Swiss.length t) 5;
      for i = 10000 to 10004 do
        check (Swiss.mem t i) "live key lost during churn"
      done;
      check (not (Swiss.mem t 9999)) "removed key still present after churn";
      check_invariants t)

(* ------------------------------------------------------------------ *)
(* 3. Multi-binding ladders (oracle-verified: stdlib gives the same).  *)

let () =
  group "multi-binding-ladder" (fun () ->
      let t = Swiss.create ~random:false 16 in
      for v = 1 to 5 do
        Swiss.add t "k" v
      done;
      check_invariants ~boxed_keys:true t;
      let expected = ref [ 5; 4; 3; 2; 1 ] in
      while !expected <> [] do
        check_ilist ~msg:"ladder stack" (Swiss.find_all t "k") !expected;
        check_eq_int ~msg:"find <> top of stack" (Swiss.find t "k")
          (List.hd !expected);
        check_eq_int ~msg:"length <> stack size" (Swiss.length t)
          (List.length !expected);
        Swiss.remove t "k";
        expected := List.tl !expected;
        check_invariants ~boxed_keys:true t
      done;
      check (not (Swiss.mem t "k")) "key present after full unwind";
      check_ilist ~msg:"find_all after unwind" (Swiss.find_all t "k") [];
      check
        (match Swiss.find t "k" with
        | exception Not_found -> true
        | _ -> false)
        "find after unwind should raise Not_found";
      (* replace at each ladder depth: overwrites the top, keeps the rest.
         Oracle: stdlib replace-at-depth-3 over [3;2;1] gives [99;2;1]. *)
      for depth = 1 to 5 do
        let t = Swiss.create ~random:false 16 in
        for v = 1 to 5 do
          Swiss.add t "k" v
        done;
        for _ = 1 to 5 - depth do
          Swiss.remove t "k"
        done;
        Swiss.replace t "k" 99;
        let expect = 99 :: List.init (depth - 1) (fun i -> depth - 1 - i) in
        check_ilist
          ~msg:(Printf.sprintf "replace at depth %d" depth)
          (Swiss.find_all t "k") expect;
        check_eq_int ~msg:"replace changed the binding count" (Swiss.length t)
          depth;
        check_invariants ~boxed_keys:true t
      done;
      (* remove of an absent key is a silent no-op *)
      let t = Swiss.create ~random:false 16 in
      Swiss.add t "a" 1;
      Swiss.remove t "zzz";
      check_eq_int ~msg:"absent remove changed length" (Swiss.length t) 1;
      check (Swiss.mem t "a") "absent remove disturbed a present key";
      check_invariants ~boxed_keys:true t)

(* ------------------------------------------------------------------ *)
(* 4. replace overwrites the stored key OBJECT (oracle-verified:
      stdlib iter sees k2 (==) after replace t k2).                    *)

let () =
  group "replace-key-object" (fun () ->
      let k1 = String.make 1 'k' and k2 = String.make 1 'k' in
      check
        (k1 = k2 && not (k1 == k2))
        "test setup: keys must be equal but physically distinct";
      let t = Swiss.create ~random:false 16 in
      Swiss.add t k1 1;
      Swiss.replace t k2 2;
      check_eq_int ~msg:"replaced value" (Swiss.find t k1) 2;
      check_eq_int ~msg:"replace must keep a single binding" (Swiss.length t) 1;
      let seen = ref [] in
      Swiss.iter (fun k v -> seen := (k, v) :: !seen) t;
      (match !seen with
      | [ (k, 2) ] ->
        check (k == k2) "iter key is not the replace argument (k2)";
        check (not (k == k1)) "iter key is still the original key object (k1)"
      | _ -> failwith "unexpected iter contents after replace");
      check_invariants ~boxed_keys:true t)

(* ------------------------------------------------------------------ *)
(* 5. add stacks key objects; remove un-shadows the ORIGINAL key object
      (oracle-verified: stdlib's surviving cons cell keeps k1).        *)

let () =
  group "add-key-object-stacking" (fun () ->
      let k1 = String.make 1 'k' and k2 = String.make 1 'k' in
      check (k1 = k2 && not (k1 == k2)) "test setup";
      let t = Swiss.create ~random:false 16 in
      Swiss.add t k1 1;
      Swiss.add t k2 2;
      check_eq_int ~msg:"length" (Swiss.length t) 2;
      let seen = ref [] in
      Swiss.iter (fun k v -> seen := (k, v) :: !seen) t;
      check_eq_int ~msg:"iter visit count" (List.length !seen) 2;
      let key_of v =
        match List.find_opt (fun (_, v') -> v' = v) !seen with
        | Some (k, _) -> k
        | None -> failwith (Printf.sprintf "binding %d missing from iter" v)
      in
      check (key_of 2 == k2) "top binding's key should be k2 (==)";
      check (key_of 1 == k1) "older binding's key should be k1 (==)";
      Swiss.remove t "k";
      let seen = ref [] in
      Swiss.iter (fun k v -> seen := (k, v) :: !seen) t;
      (match !seen with
      | [ (k, 1) ] ->
        check (k == k1) "surviving binding's key should be the original k1 (==)"
      | _ -> failwith "unexpected contents after un-shadowing remove");
      check_invariants ~boxed_keys:true t)

(* ------------------------------------------------------------------ *)
(* 6. filter_map_inplace (all sub-cases oracle-verified against stdlib;
      the remove-after-drop case is the design-review minor#2
      stranded-empty-stack regression).                                *)

let () =
  group "filter_map_inplace" (fun () ->
      (* (a) f kills the top binding, keeps (and transforms) the older one *)
      let t = Swiss.create ~random:false 16 in
      Swiss.add t "k" 1;
      Swiss.add t "k" 2;
      Swiss.filter_map_inplace
        (fun _ v -> if v = 2 then None else Some (v * 10))
        t;
      check_ilist ~msg:"kill-top" (Swiss.find_all t "k") [ 10 ];
      check_eq_int ~msg:"kill-top length" (Swiss.length t) 1;
      check_invariants ~boxed_keys:true t;
      (* (b) f keeps the top, kills the older one; then remove must empty *)
      let t = Swiss.create ~random:false 16 in
      Swiss.add t "k" 1;
      Swiss.add t "k" 2;
      Swiss.filter_map_inplace (fun _ v -> if v = 2 then Some 20 else None) t;
      check_ilist ~msg:"kill-older" (Swiss.find_all t "k") [ 20 ];
      check_eq_int ~msg:"kill-older length" (Swiss.length t) 1;
      check_invariants ~boxed_keys:true t;
      Swiss.remove t "k";
      check (not (Swiss.mem t "k"))
        "mem still true after removing the single surviving binding";
      check_eq_int ~msg:"length after remove" (Swiss.length t) 0;
      check_invariants ~boxed_keys:true t;
      (* (c) f kills ALL bindings of a key *)
      let t = Swiss.create ~random:false 16 in
      Swiss.add t "k" 1;
      Swiss.add t "k" 2;
      Swiss.add t "k" 3;
      Swiss.add t "x" 5;
      Swiss.filter_map_inplace (fun _ v -> if v = 5 then Some v else None) t;
      check (not (Swiss.mem t "k")) "key with all bindings killed still present";
      check (Swiss.mem t "x") "unrelated key lost";
      check_eq_int ~msg:"length" (Swiss.length t) 1;
      check_invariants ~boxed_keys:true t;
      (* (d) f deletes everything; table must stay consistent *)
      let t = Swiss.create ~random:false 8 in
      for i = 0 to 49 do
        Swiss.add t (string_of_int i) i
      done;
      for i = 0 to 9 do
        Swiss.add t (string_of_int i) (i + 100)
      done;
      Swiss.filter_map_inplace (fun _ _ -> None) t;
      check_eq_int ~msg:"emptied length" (Swiss.length t) 0;
      check (not (Swiss.mem t "3")) "key survived fmi None";
      check_invariants ~boxed_keys:true t;
      Swiss.add t "fresh" 7;
      check_eq_int ~msg:"add after emptying" (Swiss.find t "fresh") 7;
      check_eq_int ~msg:"length after re-add" (Swiss.length t) 1;
      check_invariants ~boxed_keys:true t;
      (* (e) each binding presented exactly once (incl. surfaced ones) *)
      let t = Swiss.create ~random:false 16 in
      Swiss.add t "a" 1;
      Swiss.add t "a" 2;
      Swiss.add t "a" 3;
      Swiss.add t "b" 4;
      Swiss.add t "b" 5;
      Swiss.add t "c" 6;
      let calls = ref 0 in
      Swiss.filter_map_inplace
        (fun _ v ->
          incr calls;
          Some (v + 1))
        t;
      check_eq_int ~msg:"f call count <> number of bindings" !calls 6;
      check_ilist ~msg:"a stack" (Swiss.find_all t "a") [ 4; 3; 2 ];
      check_ilist ~msg:"b stack" (Swiss.find_all t "b") [ 6; 5 ];
      check_ilist ~msg:"c stack" (Swiss.find_all t "c") [ 7 ];
      check_eq_int ~msg:"length preserved" (Swiss.length t) 6;
      (* and when f kills the top of a stack, the surfaced binding is
         presented too (count covers every binding exactly once) *)
      let t = Swiss.create ~random:false 16 in
      Swiss.add t "k" 1;
      Swiss.add t "k" 2;
      Swiss.add t "k" 3;
      let calls = ref 0 in
      Swiss.filter_map_inplace
        (fun _ v ->
          incr calls;
          if v = 3 then None else Some v)
        t;
      check_eq_int ~msg:"f call count with cascading pop" !calls 3;
      check_ilist ~msg:"stack after killing top" (Swiss.find_all t "k") [ 2; 1 ];
      check_invariants ~boxed_keys:true t)

(* ------------------------------------------------------------------ *)
(* 7. clear after churn / clear idempotent / reset shrinks
      (design-review oxcaml#8 regression: clear must wipe tombstones). *)

let () =
  group "clear-reset" (fun () ->
      (* churn to build tombstone debt while staying "empty", then clear:
         the table must be pristine (no tombstones, full growth budget).
         Live count stays <= 6 so a growth_left exhaustion mid-churn always
         takes the same-size-rehash arm (items + 1 <= capacity/2), never
         growth. *)
      let t = Swiss.create ~random:false 8 in
      let b0 = nbuckets t in
      let cap = b0 / 8 * 7 in
      for round = 0 to 5 do
        for i = 0 to 5 do
          Swiss.add t ((round * 6) + i) i
        done;
        for i = 0 to 5 do
          Swiss.remove t ((round * 6) + i)
        done
      done;
      check_eq_int ~msg:"churn should leave the table empty" (Swiss.length t) 0;
      check_eq_int ~msg:"low-occupancy churn must not grow the table"
        (nbuckets t) b0;
      Swiss.clear t;
      check_eq_int ~msg:"clear changed capacity" (nbuckets t) b0;
      check_pristine t;
      check_invariants t;
      for i = 0 to cap - 1 do
        Swiss.add t i i
      done;
      check_eq_int
        ~msg:"insert-to-capacity after clear grew the table (stale tombstones)"
        (nbuckets t) b0;
      check_eq_int ~msg:"length after refill" (Swiss.length t) cap;
      for i = 0 to cap - 1 do
        check_eq_int ~msg:"refill value" (Swiss.find t i) i
      done;
      check_invariants t;
      (* clear keeps capacity after growth; clear twice is idempotent *)
      let t = Swiss.create ~random:false 8 in
      let b0 = nbuckets t in
      for i = 0 to 999 do
        Swiss.add t i i
      done;
      let bg = nbuckets t in
      check (bg > b0) "setup: table should have grown";
      Swiss.clear t;
      check_eq_int ~msg:"clear must keep capacity" (nbuckets t) bg;
      check_eq_int ~msg:"clear must empty the table" (Swiss.length t) 0;
      check (not (Swiss.mem t 5)) "clear left a key behind";
      check_pristine t;
      Swiss.clear t;
      check_eq_int ~msg:"second clear changed length" (Swiss.length t) 0;
      check_eq_int ~msg:"second clear changed capacity" (nbuckets t) bg;
      check_pristine t;
      Swiss.add t 1 1;
      check_eq_int ~msg:"insert after double clear" (Swiss.find t 1) 1;
      check_invariants t;
      (* reset returns num_buckets to the create-time value *)
      Swiss.reset t;
      check_eq_int ~msg:"reset must shrink to create-time buckets" (nbuckets t)
        b0;
      check_eq_int ~msg:"reset must empty the table" (Swiss.length t) 0;
      check_pristine t;
      Swiss.add t 42 42;
      check_eq_int ~msg:"insert after reset" (Swiss.find t 42) 42;
      check_invariants t;
      (* reset on a larger create-time size returns to THAT size *)
      let t = Swiss.create ~random:false 1000 in
      let b1 = nbuckets t in
      check (b1 > b0) "setup: create 1000 should start bigger than create 8";
      for i = 0 to 9999 do
        Swiss.add t i i
      done;
      check (nbuckets t > b1) "setup: table should have grown";
      Swiss.reset t;
      check_eq_int ~msg:"reset target is the create-time capacity" (nbuckets t)
        b1;
      check_invariants t)

(* ------------------------------------------------------------------ *)
(* 8. rebuild: exact contents + recency, source intact, randomized
      source (design-review semantics#1 regression).                   *)

let () =
  group "rebuild" (fun () ->
      let t = Swiss.create ~random:false 8 in
      let dup_keys = [ "a"; "b"; "c"; "d" ] in
      List.iteri
        (fun i k ->
          for v = 1 to 3 + i do
            Swiss.add t k ((v * 10) + i)
          done)
        dup_keys;
      for i = 0 to 19 do
        Swiss.add t ("s" ^ string_of_int i) i
      done;
      let all_keys = dup_keys @ List.init 20 (fun i -> "s" ^ string_of_int i) in
      let snapshot tbl = List.map (fun k -> (k, Swiss.find_all tbl k)) all_keys in
      let pre = snapshot t in
      let pre_len = Swiss.length t in
      let pre_buckets = nbuckets t in
      check_invariants ~boxed_keys:true t;
      let rb = Swiss.rebuild ~random:false t in
      List.iter
        (fun (k, l) ->
          check_ilist ~msg:("rebuild find_all " ^ k) (Swiss.find_all rb k) l)
        pre;
      check_eq_int ~msg:"rebuild length" (Swiss.length rb) pre_len;
      check_invariants ~boxed_keys:true rb;
      (* recency preserved: remove-ladder every duplicated key on rb *)
      let rec unwind k expect =
        check_ilist ~msg:("rebuild ladder " ^ k) (Swiss.find_all rb k) expect;
        match expect with
        | [] -> ()
        | _ :: tl ->
          Swiss.remove rb k;
          unwind k tl
      in
      List.iter (fun k -> unwind k (List.assoc k pre)) dup_keys;
      check_invariants ~boxed_keys:true rb;
      (* the SOURCE is fully intact *)
      check (snapshot t = pre) "rebuild mutated its source's contents";
      check_eq_int ~msg:"source length changed" (Swiss.length t) pre_len;
      check_eq_int ~msg:"source num_buckets changed" (nbuckets t) pre_buckets;
      check_invariants ~boxed_keys:true t;
      (* rebuild of a randomized (seeded) source *)
      let ts = Swiss.create ~random:true 8 in
      for i = 0 to 49 do
        Swiss.add ts i (i * 2)
      done;
      for i = 0 to 9 do
        Swiss.add ts i ((i * 2) + 1)
      done;
      let rb2 = Swiss.rebuild ~random:false ts in
      check_eq_int ~msg:"rebuild(random source) length" (Swiss.length rb2)
        (Swiss.length ts);
      for i = 0 to 49 do
        check_ilist
          ~msg:(Printf.sprintf "rebuild(random source) find_all %d" i)
          (Swiss.find_all rb2 i)
          (if i < 10 then [ (i * 2) + 1; i * 2 ] else [ i * 2 ])
      done;
      check_invariants rb2)

(* ------------------------------------------------------------------ *)
(* 9. Reentrancy memory-safety smoke tests: must not crash; results of
      the abused operation itself are unspecified.                     *)

let () =
  group "reentrancy-smoke" (fun () ->
      (* iter whose f adds 1000 keys mid-iteration (forces resizes) *)
      let t = Swiss.create ~random:false 8 in
      for i = 0 to 4 do
        Swiss.add t ("k" ^ string_of_int i) i
      done;
      let first = ref true in
      Swiss.iter
        (fun k _ ->
          ignore (String.length k);
          if !first then begin
            first := false;
            for i = 0 to 999 do
              Swiss.add t ("new" ^ string_of_int i) i
            done
          end)
        t;
      check_eq_int ~msg:"adds from inside iter must all land" (Swiss.length t)
        1005;
      for i = 0 to 999 do
        check_eq_int ~msg:"mid-iter-added key lost"
          (Swiss.find t ("new" ^ string_of_int i))
          i
      done;
      check_invariants ~boxed_keys:true t;
      (* filter_map_inplace whose f resets the same table *)
      let t = Swiss.create ~random:false 8 in
      for i = 0 to 99 do
        Swiss.add t i i
      done;
      let first = ref true in
      Swiss.filter_map_inplace
        (fun _ v ->
          if !first then begin
            first := false;
            Swiss.reset t
          end;
          Some v)
        t;
      (* state unspecified; the table must remain usable *)
      Swiss.add t 12345 1;
      check_eq_int ~msg:"table unusable after reentrant reset"
        (Swiss.find t 12345) 1;
      ignore (Swiss.length t);
      check_invariants t;
      (* to_seq captured, then 1000 adds forcing several resizes, then the
         rest of the seq forced: no crash, consumed pairs well-typed *)
      let t = Swiss.create ~random:false 8 in
      for i = 0 to 4 do
        Swiss.add t ("k" ^ string_of_int i) i
      done;
      let b_before = nbuckets t in
      let s = Swiss.to_seq t in
      let rest =
        match s () with
        | Seq.Nil -> (Seq.empty : (string * int) Seq.t)
        | Seq.Cons ((k, v), rest) ->
          ignore (String.length k);
          ignore (v : int);
          rest
      in
      for i = 5 to 1004 do
        Swiss.add t ("k" ^ string_of_int i) i
      done;
      check (nbuckets t > b_before) "setup: adds should have forced resizes";
      Seq.iter
        (fun (k, v) ->
          ignore (String.length k);
          ignore (v : int))
        rest;
      check_invariants ~boxed_keys:true t;
      (* functor variant: an H.equal that mutates the table on a flag *)
      let bomb : (unit -> unit) option ref = ref None in
      let module H = struct
        type t = int

        let equal a b =
          (match !bomb with
          | Some f ->
            bomb := None;
            f ()
          | None -> ());
          Int.equal a b

        let hash x = Swiss.hash x
      end in
      let module M = Swiss.Make (H) in
      let m = M.create 8 in
      for i = 0 to 99 do
        M.add m i i
      done;
      bomb := Some (fun () -> M.reset m);
      ignore (M.find_opt m 50);
      (* equal fired a reset mid-probe; must not crash, must stay usable *)
      M.add m 7 70;
      check_eq_int ~msg:"functor table unusable after reentrant reset"
        (M.find m 7) 70;
      M.remove m 7;
      check (not (M.mem m 7)) "remove broken after reentrant reset";
      check_raw_invariants (Obj.repr m);
      (* clear fired from inside a mutating op (add's upsert walk) *)
      let m2 = M.create 8 in
      for i = 0 to 99 do
        M.add m2 i i
      done;
      bomb := Some (fun () -> M.clear m2);
      M.add m2 50 1;
      (* unspecified state; must not crash and must stay usable *)
      M.add m2 8 80;
      check_eq_int ~msg:"functor table unusable after reentrant clear"
        (M.find m2 8) 80;
      M.remove m2 8;
      ignore (M.length m2))

(* ------------------------------------------------------------------ *)
(* 10. stats shape (this implementation's documented representation:
       a "bucket" is a distinct-key slot; histo.(j), j>=1, counts keys
       with j bindings; no comparison with stdlib beyond num_bindings). *)

let () =
  group "stats-shape" (fun () ->
      let t = Swiss.create ~random:false 16 in
      Swiss.add t "a" 1;
      Swiss.add t "a" 2;
      Swiss.add t "a" 3;
      Swiss.add t "b" 4;
      Swiss.add t "b" 5;
      Swiss.add t "c" 6;
      let st = Swiss.stats t in
      check_eq_int ~msg:"num_bindings <> length" st.Swiss.num_bindings
        (Swiss.length t);
      check_eq_int ~msg:"histogram must sum to num_buckets"
        (Array.fold_left ( + ) 0 st.Swiss.bucket_histogram)
        st.Swiss.num_buckets;
      check_eq_int ~msg:"max_bucket_length" st.Swiss.max_bucket_length 3;
      check_eq_int ~msg:"histogram length"
        (Array.length st.Swiss.bucket_histogram)
        (st.Swiss.max_bucket_length + 1);
      check_eq_int ~msg:"keys with 3 bindings" st.Swiss.bucket_histogram.(3) 1;
      check_eq_int ~msg:"keys with 2 bindings" st.Swiss.bucket_histogram.(2) 1;
      check_eq_int ~msg:"keys with 1 binding" st.Swiss.bucket_histogram.(1) 1;
      check_eq_int ~msg:"empty buckets" st.Swiss.bucket_histogram.(0)
        (st.Swiss.num_buckets - 3))

(* ------------------------------------------------------------------ *)
(* 11. Exceptions: Not_found only from find; create never raises.      *)

let () =
  group "exceptions-and-create" (fun () ->
      let t = Swiss.create ~random:false 16 in
      Swiss.add t "a" 1;
      check
        (match Swiss.find t "missing" with
        | exception Not_found -> true
        | _ -> false)
        "find on an absent key must raise Not_found";
      check (Swiss.find_opt t "missing" = None) "find_opt must not raise";
      check (not (Swiss.mem t "missing")) "mem must not raise";
      Swiss.remove t "missing";
      (* must not raise *)
      check (Swiss.find_all t "missing" = []) "find_all must return []";
      check_eq_int ~msg:"absent-key probes disturbed the table"
        (Swiss.length t) 1;
      List.iter
        (fun n ->
          let t = Swiss.create ~random:false n in
          Swiss.add t 1 10;
          Swiss.add t 2 20;
          check_eq_int
            ~msg:(Printf.sprintf "create %d: find" n)
            (Swiss.find t 1) 10;
          check_eq_int ~msg:(Printf.sprintf "create %d: length" n)
            (Swiss.length t) 2;
          check_invariants t)
        [ -5; 0; 1 ])

(* ------------------------------------------------------------------ *)
(* 12. nan / -0.0 keys via the generic interface (compare-based
       equality; oracle-verified against stdlib).                      *)

let () =
  group "float-keys" (fun () ->
      let t = Swiss.create ~random:false 16 in
      Swiss.add t nan 1;
      Swiss.add t (0.0 /. 0.0) 2;
      (* a distinct nan computation; compare nan nan' = 0 *)
      check (Swiss.mem t nan) "nan key must be found (compare-based equality)";
      check_eq_int ~msg:"find nan" (Swiss.find t nan) 2;
      check (Swiss.find_opt t nan = Some 2) "find_opt nan";
      check_ilist ~msg:"nan stack" (Swiss.find_all t nan) [ 2; 1 ];
      Swiss.remove t nan;
      check_ilist ~msg:"nan stack after remove" (Swiss.find_all t nan) [ 1 ];
      check_invariants ~boxed_keys:true t;
      let t = Swiss.create ~random:false 16 in
      Swiss.add t (-0.0) 7;
      check (Swiss.mem t 0.0) "-0.0 and 0.0 must be the same key";
      check_eq_int ~msg:"find via +0.0" (Swiss.find t 0.0) 7;
      Swiss.replace t 0.0 8;
      check_eq_int ~msg:"replace via +0.0 visible via -0.0"
        (Swiss.find t (-0.0))
        8;
      check_eq_int ~msg:"still a single binding" (Swiss.length t) 1;
      check_invariants ~boxed_keys:true t)

(* ------------------------------------------------------------------ *)
(* 13. Randomization. Runs LAST: randomize () is one-way and global.   *)

let () =
  group "randomization" (fun () ->
      (* two ~random:false tables with identical insert sequences iterate
         identically (determinism) *)
      let build () =
        let t = Swiss.create ~random:false 16 in
        for i = 0 to 199 do
          Swiss.add t (i * 7) i
        done;
        for i = 0 to 49 do
          Swiss.add t (i * 7) (i + 1000)
        done;
        t
      in
      let order t = List.rev (Swiss.fold (fun k v acc -> (k, v) :: acc) t []) in
      let t1 = build () and t2 = build () in
      check
        (order t1 = order t2)
        "identical ~random:false tables must iterate identically";
      check_eq_int ~msg:"fold must visit every binding"
        (List.length (order t1))
        250;
      (* MakeSeeded ~random:true tables exist and work (no order asserts) *)
      let module SH = struct
        type t = int

        let equal = Int.equal
        let seeded_hash seed x = Swiss.seeded_hash seed x
      end in
      let module MS = Swiss.MakeSeeded (SH) in
      let ms = MS.create ~random:true 16 in
      for i = 0 to 99 do
        MS.add ms i (i * 2)
      done;
      check_eq_int ~msg:"MakeSeeded ~random:true find" (MS.find ms 42) 84;
      check_eq_int ~msg:"MakeSeeded ~random:true length" (MS.length ms) 100;
      check (not (MS.mem ms 100)) "MakeSeeded ~random:true spurious mem";
      (* Make ignores randomize() entirely: still deterministic after *)
      Swiss.randomize ();
      check (Swiss.is_randomized ()) "randomize did not set the global flag";
      let module H = struct
        type t = int

        let equal = Int.equal
        let hash x = Swiss.hash x
      end in
      let module M = Swiss.Make (H) in
      let mbuild () =
        let m = M.create 16 in
        for i = 0 to 199 do
          M.add m (i * 3) i
        done;
        m
      in
      let morder m = List.rev (M.fold (fun k v acc -> (k, v) :: acc) m []) in
      let m1 = mbuild () and m2 = mbuild () in
      check
        (morder m1 = morder m2)
        "Make tables must stay deterministic after randomize()";
      check_eq_int ~msg:"Make fold visits everything"
        (List.length (morder m1))
        200;
      (* generic ~random:false stays deterministic after randomize() too *)
      let t3 = build () and t4 = build () in
      check
        (order t3 = order t4)
        "~random:false tables must stay deterministic after randomize()";
      check
        (order t3 = order t1)
        "~random:false table layout changed after randomize()")

(* ------------------------------------------------------------------ *)

let () =
  if !failures = 0 then print_endline "test_unit: all groups passed"
  else begin
    Printf.eprintf "test_unit: %d group(s) FAILED\n%!" !failures;
    exit 1
  end

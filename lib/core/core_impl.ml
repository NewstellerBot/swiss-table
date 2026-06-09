(**************************************************************************)
(*                                                                        *)
(*   Swiss core — the Swiss-table engine, functorized over the group     *)
(*   probing implementation (8-wide portable SWAR or 16-wide NEON).      *)
(*   See swiss/docs/design.md. Split out of swiss.ml verbatim.           *)
(*                                                                        *)
(**************************************************************************)

open! Stdlib
[@@@ocaml.flambda_o3]

(* ------------------------------------------------------------------ *)
(* Hash functions: exactly stdlib's (API §2.5)                         *)
(* ------------------------------------------------------------------ *)

external seeded_hash_param :
  int -> int -> int -> 'a -> int @@ portable = "caml_hash_exn"

(* ------------------------------------------------------------------ *)
(* Randomization machinery: exactly stdlib's (API §2.3)                *)
(* ------------------------------------------------------------------ *)

let randomized_default =
  let params =
    try Sys.getenv "OCAMLRUNPARAM" with Not_found ->
    try Sys.getenv "CAMLRUNPARAM" with Not_found -> "" in
  String.contains params 'R'

let randomized = Atomic.make randomized_default

let randomize () = Atomic.set randomized true
let is_randomized () = Atomic.get randomized

module Rng : sig
  val bits : unit -> int
end = struct
  (* This is safe since [bits] is a C call that cannot be preempted,
     we do not yield, and we do not borrow the state. *)
  let key = Domain.Safe.DLS.new_key Random.State.make_self_init
  let[@inline] bits () =
    Random.State.bits (Obj.magic_uncontended (Domain.Safe.DLS.get key))
end

(* ------------------------------------------------------------------ *)
(* Control bytes and SWAR group operations (ALG §1–§2)                 *)
(* ------------------------------------------------------------------ *)

(* ctrl byte encoding (hashbrown): EMPTY = 0xFF, DELETED = 0x80,
   FULL = h2 in [0, 0x7F]. *)
let ctrl_empty = '\xff'
let ctrl_deleted = '\x80'

let[@inline] is_full_byte ch = Char.code ch < 0x80

(* ------------------------------------------------------------------ *)
(* Group probing contract                                              *)
(* ------------------------------------------------------------------ *)

(* A group implementation examines [width] control bytes per probe
   step. Mask values are opaque native ints whose format is the
   implementation's choice — the engine only manipulates them through
   the helpers below. All functions must be allocation-free and
   [@inline]; the unboxed-tuple returns keep everything in registers. *)
module type GROUP = sig @@ portable
  val width : int

  (* probe_find ctrl pos tag = #(match_mask, empty_mask) over the
     [width] ctrl bytes at [pos] (unaligned; in-bounds by the ctrl tail
     invariant). [tag] is a FULL h2 byte in [0, 0x7F]. match_mask may
     contain false positives (the engine confirms every candidate with
     key equality) but never matches EMPTY/DELETED. The engine only
     tests empty_mask <> 0 here. *)
  val probe_find : Bytes.t -> int -> int -> #(int * int)

  (* probe_insert additionally returns the empty-or-deleted mask. *)
  val probe_insert : Bytes.t -> int -> int -> #(int * int * int)

  (* Positionally exact masks (deletion rule / fresh-core inserts). *)
  val match_empty : Bytes.t -> int -> int
  val match_empty_or_deleted : Bytes.t -> int -> int

  (* Mask iteration: lowest_idx m (m <> 0) = byte offset in
     [0, width); counts are byte-position counts, [width] for m = 0. *)
  val lowest_idx : int -> int
  val clear_lowest : int -> int
  val trailing_zero_count : int -> int
  val leading_zero_count : int -> int
end


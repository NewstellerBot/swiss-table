(* 8 control bytes processed at once via 64-bit SWAR. The group word
   must be int64: bit 63 (byte 7's match bit) does not fit a native
   int. Loads are little-endian on every platform so that low mask
   bits correspond to low byte addresses.

   Mask format: derived from the SWAR match words by [lsr 7] — a single
   bit per matching byte, at int bit position 8*i for byte offset i.
   Allocation discipline: the int64 group word never escapes a
   function (it is dead before the engine's eq calls); the returned
   masks are native ints in unboxed tuples. *)

external get64u : Bytes.t -> int -> int64 @@ portable = "%caml_bytes_get64u"
external swap64 : int64 -> int64 @@ portable = "%bswap_int64"

let width = 8

let[@inline] load ctrl pos =
  let g = get64u ctrl pos in
  if Sys.big_endian then swap64 g else g

let lsbs = 0x0101010101010101L
let msbs = 0x8080808080808080L

let[@inline] repeat b = Int64.mul (Int64.of_int b) lsbs

(* Bit 8i+7 set iff ctrl byte i MAY equal [b]: false positives are
   possible (only directly above a true match) and are resolved by the
   engine's key equality check. Never matches EMPTY/DELETED. *)
let[@inline] match_byte_w g b =
  let cmp = Int64.logxor g (repeat b) in
  Int64.logand (Int64.logand (Int64.sub cmp lsbs) (Int64.lognot cmp)) msbs

(* Among special bytes only EMPTY (0xFF) has bit 6 set. *)
let[@inline] match_empty_w g =
  Int64.logand (Int64.logand g (Int64.shift_left g 1)) msbs

let[@inline] match_empty_or_deleted_w g = Int64.logand g msbs

(* Move the match bits (at 8i+7) into a native int (at 8i). Bit 63
   would be destroyed by Int64.to_int, hence the prior shift. *)
let[@inline] mask_to_int m = Int64.to_int (Int64.shift_right_logical m 7)

let[@inline] probe_find ctrl pos tag =
  let g = load ctrl pos in
  #(mask_to_int (match_byte_w g tag), mask_to_int (match_empty_w g))

let[@inline] probe_insert ctrl pos tag =
  let g = load ctrl pos in
  #( mask_to_int (match_byte_w g tag),
     mask_to_int (match_empty_w g),
     mask_to_int (match_empty_or_deleted_w g) )

let[@inline] match_empty ctrl pos = mask_to_int (match_empty_w (load ctrl pos))

let[@inline] match_empty_or_deleted ctrl pos =
  mask_to_int (match_empty_or_deleted_w (load ctrl pos))

(* Iteration over the sparse masks (single bits at 0, 8, ..., 56). *)
let[@inline] lowest_idx mi =
  let k = ref 0 and v = ref mi in
  while !v land 0xff = 0 do
    v := !v lsr 8;
    incr k
  done;
  !k

let[@inline] clear_lowest mi = mi land (mi - 1)
let[@inline] trailing_zero_count mi = if mi = 0 then 8 else lowest_idx mi

let[@inline] leading_zero_count mi =
  if mi = 0 then 8
  else begin
    let k = ref 0 and v = ref (mi lsr 8) in
    while !v <> 0 do
      v := !v lsr 8;
      incr k
    done;
    7 - !k
  end

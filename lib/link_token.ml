open! Core

let byte_length = 32
let length = 43
let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

(* Unpadded base64url (RFC 4648 section 5); written out because the encoders at hand
   produce the padded standard alphabet. *)
let encode bytes =
  let n = String.length bytes in
  let buf = Buffer.create ((n * 4 / 3) + 4) in
  let byte i = if i < n then Char.to_int bytes.[i] else 0 in
  let rec go i =
    if i < n
    then (
      let v = (byte i lsl 16) lor (byte (i + 1) lsl 8) lor byte (i + 2) in
      let chars = Int.min 4 ((((n - i) * 8) + 5) / 6) in
      for k = 0 to chars - 1 do
        Buffer.add_char buf alphabet.[(v lsr (18 - (6 * k))) land 63]
      done;
      go (i + 3))
  in
  go 0;
  Buffer.contents buf
;;

let check s =
  if String.length s <> length
  then
    Or_error.error_s [%message "link token has the wrong length" ~expected:(length : int)]
  else if not (String.for_all s ~f:(String.mem alphabet))
  then Or_error.error_string "link token has a character outside base64url"
  else if (* 43 characters carry 258 bits; the last character's two low bits must be zero
             for the text to be the canonical encoding of 32 bytes. *)
          String.index_exn alphabet s.[length - 1] land 3 <> 0
  then Or_error.error_string "link token is not a canonical encoding"
  else Ok s
;;

module T = struct
  type t = string [@@deriving compare, equal, hash]

  let sexp_of_t = sexp_of_string
  let t_of_sexp sexp = Or_error.ok_exn (check (string_of_sexp sexp))

  include
    Binable.Of_binable_without_uuid [@alert "-legacy"]
      (String)
      (struct
        type t = string

        let to_binable = Fn.id
        let of_binable s = Or_error.ok_exn (check s)
      end)
end

include T

let of_random_bytes bytes =
  if String.length bytes <> byte_length
  then
    Or_error.error_s
      [%message
        "link token needs exactly 32 random bytes" ~got:(String.length bytes : int)]
  else Ok (encode bytes)
;;

(* Cryptokit's [system_rng] is implemented on Windows only; the device works on every
   Unix. *)
let default_rng = lazy (Cryptokit.Random.device_rng "/dev/urandom")

let generate ?rng () =
  let rng =
    match rng with
    | Some rng -> rng
    | None -> force default_rng
  in
  let bytes = Bytes.create byte_length in
  rng#random_bytes bytes 0 byte_length;
  encode (Bytes.to_string bytes)
;;

let of_string = check
let to_string t = t

module Stable = struct
  module V1 = T
end

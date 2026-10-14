open! Core

let max_length = 35

let normalise s =
  String.map s ~f:(fun c -> if Char.is_whitespace c || Char.to_int c < 0x20 || Char.to_int c = 0x7f then ' ' else c)
  |> String.split ~on:' '
  |> List.filter ~f:(fun w -> not (String.is_empty w))
  |> String.concat ~sep:" "
;;

(* UTF-8 continuation bytes are 10xxxxxx; every other byte starts a code point. *)
let utf8_length s = String.count s ~f:(fun c -> Char.to_int c land 0xC0 <> 0x80)

let check s =
  if String.is_empty s
  then Or_error.error_string "empty text"
  else if not (Stdlib.String.is_valid_utf_8 s)
  then Or_error.error_string "text is not UTF-8"
  else (
    let length = utf8_length s in
    if length > max_length
    then Or_error.error_s [%message "text too long" (length : int) (max_length : int)]
    else Ok s)
;;

module T = struct
  type t = string [@@deriving compare, equal, hash]

  let of_string_or_error s = check (normalise s)
  let sexp_of_t = sexp_of_string
  let t_of_sexp sexp = Or_error.ok_exn (of_string_or_error (string_of_sexp sexp))

  include
    Binable.Of_binable_without_uuid [@alert "-legacy"]
      (String)
      (struct
        type t = string

        let to_binable = Fn.id
        let of_binable s = Or_error.ok_exn (of_string_or_error s)
      end)
end

include T

let of_string = of_string_or_error

let of_optional = function
  | None -> Ok None
  | Some s ->
    let s = normalise s in
    if String.is_empty s then Ok None else Or_error.map (check s) ~f:Option.some
;;

let to_string t = t
let length t = utf8_length t

module Stable = struct
  module V1 = T
end

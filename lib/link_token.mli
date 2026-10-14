(** The public handle of a payment link: 32 random bytes from a cryptographic generator,
    written as 43 characters of unpadded base64url.

    A token is the only thing a payer needs to see a link, so it must not be guessable:
    256 bits of randomness put guessing out of reach however many links exist. It is
    never derived from the link id, the owner or a counter. *)

open! Core

type t [@@deriving sexp, compare, equal, hash]

(** 32. *)
val byte_length : int

(** 43. *)
val length : int

(** A fresh token from [rng], by default the operating system's generator
    ([/dev/urandom]). *)
val generate : ?rng:Cryptokit.Random.rng -> unit -> t

(** The token for exactly {!byte_length} bytes; for tests and for callers with their own
    generator. *)
val of_random_bytes : string -> t Or_error.t

(** Parses the text form; fails unless it is {!length} base64url characters that decode
    to {!byte_length} bytes. *)
val of_string : string -> t Or_error.t

val to_string : t -> string

module Stable : sig
  module V1 : sig
    (** The text form; decoding checks it again. *)
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
  end
end

(** Short free text shown to the other party: a request's note, a link's note, a split's
    title.

    Input is normalised the way payment references are: control characters become spaces,
    runs of white space collapse to one space, and the ends are trimmed. The result must
    be valid UTF-8 of at most {!max_length} characters (code points, not bytes), which
    fits the remittance field of every common payment scheme. *)

open! Core

type t [@@deriving sexp, compare, equal, hash]

(** 35 characters. *)
val max_length : int

(** The normalised form of [s], before any length check. *)
val normalise : string -> string

(** A non-empty note. Fails when the normalised text is empty, longer than {!max_length}
    characters or not UTF-8. *)
val of_string : string -> t Or_error.t

(** An optional note: [None] and text that normalises to nothing give [Ok None]. *)
val of_optional : string option -> t option Or_error.t

(** The normalised text. *)
val to_string : t -> string

(** Number of characters (code points). *)
val length : t -> int

module Stable : sig
  module V1 : sig
    (** The plain string; decoding checks it again. *)
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
  end
end

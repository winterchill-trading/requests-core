(** Identifiers checked once, at the edge.

    An id is 1 to {!max_length} characters from [A-Z a-z 0-9 _ - .]. The short alphabet
    and length keep every idempotency key built from ids (a link id and a payer id
    together) within the ledger's key limit, and keep ids safe to print in a log line or a
    statement reference without quoting. *)

open! Core

module type S = sig
  type t [@@deriving sexp, compare, equal, hash, quickcheck]

  include Identifiable.S with type t := t

  (** [of_string] raises on an invalid id; this is the non-raising form. *)
  val of_string_or_error : string -> t Or_error.t

  module Stable : sig
    module V1 : sig
      (** Bin_prot is the plain string; decoding checks the id again. *)
      type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
    end
  end
end

(** 48 characters. *)
val max_length : int

(** Why [s] is not a valid id, if it is not. *)
val check : string -> unit Or_error.t

(** One fresh id type per use, so a request id cannot be passed where a link id is
    expected. *)
module Make
    (_ : sig
       (** Used in error messages, e.g. ["Requests_core.Request_id"]. *)
       val module_name : string
     end)
    () : S

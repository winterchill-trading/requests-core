(** A customer as the other side of a request sees them: an id and a display name. *)

open! Core

type t = private
  { customer : Customer_id.t
  ; name : string (** display name, trimmed and non-empty *)
  }
[@@deriving sexp, compare, equal, hash, fields]

(** Fails on a name that is empty after trimming. *)
val create : customer:Customer_id.t -> name:string -> t Or_error.t

val create_exn : customer:Customer_id.t -> name:string -> t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
  end
end

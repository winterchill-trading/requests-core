(** Where a money request stands.

    {v
    Pending ──pay (payer)───────> Paid
       │───decline (payer)───────> Declined
       │───cancel (requester)────> Cancelled
       └───lifetime runs out─────> Expired
    v}

    Every state but [Pending] is final. *)

open! Core

type t =
  | Pending
  | Paid
  | Declined
  | Cancelled
  | Expired
[@@deriving sexp, compare, equal, hash, enumerate, quickcheck]

(** Everything but [Pending]. *)
val is_final : t -> bool

(** ["pending"], ["paid"], ... *)
val to_string : t -> string

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
  end
end

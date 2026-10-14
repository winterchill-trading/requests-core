(** Where a payment link stands.

    {v
    Active ──last allowed payment──> Completed
       │────revoke (owner)─────────> Revoked
       └────expiry passes──────────> Expired   (read, never stored)
    v}

    A link is stored [Active], [Completed] or [Revoked]; an active link past its expiry
    reads as [Expired] at once, without a write. *)

open! Core

type t =
  | Active
  | Completed
  | Revoked
  | Expired
[@@deriving sexp, compare, equal, hash, enumerate, quickcheck]

(** ["active"], ["completed"], ... *)
val to_string : t -> string

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
  end
end

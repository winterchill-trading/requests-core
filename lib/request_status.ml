open! Core

module Stable = struct
  module V1 = struct
    type t =
      | Pending
      | Paid
      | Declined
      | Cancelled
      | Expired
    [@@deriving bin_io, sexp, compare, equal, hash, enumerate, quickcheck]
  end
end

include Stable.V1

let is_final = function
  | Pending -> false
  | Paid | Declined | Cancelled | Expired -> true
;;

let to_string t = String.lowercase (Sexp.to_string (sexp_of_t t))

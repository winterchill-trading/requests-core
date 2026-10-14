open! Core

module Stable = struct
  module V1 = struct
    type t =
      | Active
      | Completed
      | Revoked
      | Expired
    [@@deriving bin_io, sexp, compare, equal, hash, enumerate, quickcheck]
  end
end

include Stable.V1

let to_string t = String.lowercase (Sexp.to_string (sexp_of_t t))

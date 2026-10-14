open! Core

module Stable = struct
  module V1 = struct
    type t =
      { customer : Customer_id.Stable.V1.t
      ; name : string
      }
    [@@deriving bin_io, sexp, compare, equal, hash, fields]
  end
end

include Stable.V1

let create ~customer ~name =
  let name = String.strip name in
  if String.is_empty name
  then Or_error.error_s [%message "empty display name" (customer : Customer_id.t)]
  else Ok { customer; name }
;;

let create_exn ~customer ~name = Or_error.ok_exn (create ~customer ~name)

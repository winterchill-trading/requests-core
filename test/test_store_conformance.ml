open! Core
open Requests_core
module Store = Store_memory.Make (Monad.Ident)
module Conformance = Store_conformance.Make (Monad.Ident) (Store)

let%expect_test "the in-memory store passes the conformance scenarios" =
  print_s [%sexp (Conformance.check (Store.create ()) : unit Or_error.t)];
  [%expect {| (Ok ()) |}]
;;

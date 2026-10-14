open! Core
open Requests_core

let t0 = Time_ns.of_string_with_utc_offset "2026-10-13 09:00:00Z"
let after_min n = Time_ns.add t0 (Time_ns.Span.of_int_sec (60 * n))
let after_day n = Time_ns.add t0 (Time_ns.Span.of_day (Float.of_int n))
let eur s = Money.Amount.of_decimal_string Money.Currency.eur s |> Or_error.ok_exn
let gbp s = Money.Amount.of_decimal_string Money.Currency.gbp s |> Or_error.ok_exn
let customer = Customer_id.of_string
let party id name = Party.create_exn ~customer:(customer id) ~name
let alice = party "alice" "Alice"
let bob = party "bob" "Bob"
let carol = party "carol" "Carol"

let account (p : Party.t) =
  Ledger.Account_id.of_string ("customer:" ^ Customer_id.to_string p.customer ^ "/eur")
;;

let ok = function
  | Ok x -> x
  | Error r -> raise_s [%message "refused" (r : Refusal.t)]
;;

let print_refusal = function
  | Ok _ -> print_endline "accepted"
  | Error r -> print_s [%message (Refusal.code r) ~_:(r : Refusal.t)]
;;

let print_notices notices =
  List.iter notices ~f:(fun (n : Notice.t) ->
    print_s [%message (Notice.key n) ~to_:(n.recipient : Customer_id.t)])
;;

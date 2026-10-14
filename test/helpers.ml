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

let clearing = Ledger.Account_id.of_string "external:clearing/eur"

let apply_record b event =
  Ledger.Balances.apply b { seq = Ledger.Balances.next_seq b; event } |> Or_error.ok_exn
;;

let ledger funded =
  let accounts =
    Ledger.Account.create ~allow_negative:true clearing Asset
    :: List.map funded ~f:(fun (p, _) -> Ledger.Account.create (account p) Liability)
    @ Settlement.accounts [ Money.Currency.eur ]
  in
  let b =
    List.fold accounts ~init:Ledger.Balances.empty ~f:(fun b a ->
      apply_record b (Account_opened a))
  in
  List.fold funded ~init:b ~f:(fun b (p, amount) ->
    if Money.Amount.is_zero (eur amount)
    then b
    else (
    let entry =
      Ledger.Entry.create
        ~idempotency_key:
          (Ledger.Idempotency_key.of_string ("fund:" ^ Customer_id.to_string p.customer))
        ~kind:(Transfer "deposit")
        ~code:Deposit
        ~effective_at:t0
        ~recorded_at:t0
        [ Ledger.Posting.debit clearing (eur amount)
        ; Ledger.Posting.credit (account p) (eur amount)
        ]
      |> Or_error.ok_exn
    in
    apply_record b (Posted entry)))
;;

let print_entries entries =
  List.iter entries ~f:(fun (e : Ledger.Entry.t) ->
    printf
      "%s  %s  ref=%s\n"
      (Ledger.Idempotency_key.to_string e.idempotency_key)
      (Ledger.Entry.Code.to_string e.code)
      e.reference;
    List.iter e.postings ~f:(fun p ->
      printf
        "  %-6s %-36s %s\n"
        (match p.side with
         | Debit -> "debit"
         | Credit -> "credit")
        (Ledger.Account_id.to_string p.account)
        (Money.Amount.to_string p.amount)))
;;

let print_balances b accounts =
  List.iter accounts ~f:(fun a ->
    printf
      "%-36s %s\n"
      (Ledger.Account_id.to_string a)
      (Money.Amount.to_string (Ledger.Balances.posted b a Money.Currency.eur)))
;;

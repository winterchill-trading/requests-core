open! Core
open Requests_core
open Helpers

let settlement_account =
  Payments_core.Booking.Chart.default.settlement Intraledger Money.Currency.eur
;;

let instruction amount =
  Settlement.Instruction.for_request
    (Request_id.of_string "r1")
    ~payer:bob
    ~from:(account bob)
    ~payee:alice
    ~to_:(account alice)
    ~amount:(eur amount)
    ~note:(Some (Note.of_string "pizza" |> Or_error.ok_exn))
  |> Or_error.ok_exn
;;

let authorization : Payments_core.Sca.Authorization.t =
  Sca (Payments_core.Sca.Id.of_string "challenge-1")
;;

let%expect_test "a request payment books hold, capture and deposit" =
  let b = ledger [ bob, "50.00"; alice, "0.00" ] in
  let i = instruction "12.50" in
  print_s [%sexp (Settlement.check_funds b i : (unit, Refusal.t) Result.t)];
  let booked = Settlement.book b i ~authorization ~at:(after_min 1) |> Or_error.ok_exn in
  print_entries booked.entries;
  let b = Payments_core.Booking.apply b booked.entries |> Or_error.ok_exn in
  print_balances b [ account bob; account alice; settlement_account ];
  print_s
    [%message
      ""
        ~outgoing:(booked.outgoing.id : Payments_core.Transfer.Id.t)
        ~outgoing_status:(booked.outgoing.status : Payments_core.Transfer.Status.t)
        ~incoming:(booked.incoming.id : Payments_core.Transfer.Id.t)
        ~incoming_status:(booked.incoming.status : Payments_core.Transfer.Status.t)];
  Ledger.Trial_balance.of_balances b |> Ledger.Trial_balance.check |> Or_error.ok_exn;
  [%expect
    {|
    (Ok ())
    request:r1/hold  TRANSFER_INTRALEDGER  ref=request:r1/out
      debit  customer:bob/eur                     12.50 EUR
      credit customer:bob/eur/pending             12.50 EUR
    request:r1/capture  TRANSFER_INTRALEDGER  ref=request:r1/out
      debit  customer:bob/eur/pending             12.50 EUR
      credit settlement:intraledger/EUR           12.50 EUR
    request:r1/deposit  DEPOSIT  ref=request:r1/in
      debit  settlement:intraledger/EUR           12.50 EUR
      credit customer:alice/eur                   12.50 EUR
    customer:bob/eur                     37.50 EUR
    customer:alice/eur                   12.50 EUR
    settlement:intraledger/EUR           0.00 EUR
    ((outgoing request:r1/out) (outgoing_status Settled) (incoming request:r1/in)
     (incoming_status Settled))
    |}]
;;

let%expect_test "booking twice gives identical entries, which the ledger books once" =
  let b = ledger [ bob, "50.00"; alice, "0.00" ] in
  let i = instruction "12.50" in
  let first = Settlement.book b i ~authorization ~at:(after_min 1) |> Or_error.ok_exn in
  let b' = Payments_core.Booking.apply b first.entries |> Or_error.ok_exn in
  let again = Settlement.book b i ~authorization ~at:(after_min 1) |> Or_error.ok_exn in
  print_s
    [%sexp (List.equal Ledger.Entry.equal first.entries again.entries : bool)];
  (* The balances refuse keys they have booked, so the money moves once. *)
  print_s
    [%sexp
      (Payments_core.Booking.apply b' again.entries |> Result.is_ok : bool)];
  [%expect {|
    true
    false
    |}]
;;

let%expect_test "insufficient funds is a typed refusal" =
  let b = ledger [ bob, "10.00"; alice, "0.00" ] in
  let i = instruction "12.50" in
  print_s [%sexp (Settlement.check_funds b i : (unit, Refusal.t) Result.t)];
  print_s
    [%sexp
      (Settlement.book b i ~authorization ~at:(after_min 1) |> Result.is_ok : bool)];
  [%expect
    {|
    (Error (Insufficient_funds (available "10.00 EUR") (required "12.50 EUR")))
    false
    |}]
;;

let%expect_test "link keys are scoped to the payer" =
  let key payer =
    Settlement.Instruction.for_link
      (Link_id.of_string "l1")
      ~payer
      ~from:(account payer)
      ~payee:alice
      ~to_:(account alice)
      ~amount:(eur "5.00")
      ~note:None
    |> Or_error.ok_exn
    |> fun (i : Settlement.Instruction.t) -> Ledger.Idempotency_key.to_string i.key
  in
  print_s [%sexp (List.map [ bob; carol ] ~f:key : string list)];
  [%expect {| (link:l1:bob link:l1:carol) |}]
;;

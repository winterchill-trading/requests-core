open! Core
open Requests_core
open Helpers

let token n =
  Link_token.of_random_bytes (String.make Link_token.byte_length (Char.of_int_exn n))
  |> Or_error.ok_exn
;;

let link ?amount ?note ?lifetime ?(usage = Link.Usage.Single_use) () =
  Link.create
    ~id:(Link_id.of_string "l1")
    ~token:(token 1)
    ~owner:alice
    ~account:(account alice)
    ~currency:Money.Currency.eur
    ?amount
    ?note:(Option.map note ~f:(fun s -> Note.of_string s |> Or_error.ok_exn))
    ?lifetime
    ~usage
    ~now:t0
    ()
;;

let pay ?amount ?(currency = Money.Currency.eur) l (p : Party.t) ~min =
  Link.pay l ~payer:p ~from:(account p) ~from_currency:currency ?amount ~now:(after_min min) ()
;;

let show l ~viewer ~now =
  print_s
    [%sexp
      (Link.public_view l ~viewer:(Option.map viewer ~f:(fun (p : Party.t) -> p.customer)) ~now
       : Link.Public.t * Link.Public.viewer)]
;;

let%expect_test "a single-use fixed link: one payment completes it" =
  let l = link ~amount:(eur "20.00") ~note:"concert ticket" () |> ok in
  show l ~viewer:None ~now:t0;
  [%expect
    {|
    ((Available (name Alice) (amount ("20.00 EUR")) (currency EUR)
      (note ("concert ticket")))
     ((own false) (paid false)))
    |}];
  let step = pay l bob ~min:1 |> ok in
  print_notices step.notices;
  print_s
    [%message
      ""
        ~status:(step.link.status : Link_status.t)
        ~key:(step.settlement.key : Ledger.Idempotency_key.t)
        ~collected:(Link.collected step.link : Money.Amount.t)];
  [%expect
    {|
    (link:l1:paid:bob (to_ alice))
    (link:l1:completed (to_ alice))
    ((status Completed) (key link:l1:bob) (collected "20.00 EUR"))
    |}];
  (* Name, amount and note disappear once the link cannot be paid. *)
  show step.link ~viewer:(Some bob) ~now:(after_min 2);
  print_refusal (pay step.link bob ~min:2);
  print_refusal (pay step.link carol ~min:2);
  [%expect
    {|
    ((Unavailable Completed) ((own false) (paid true)))
    (already_paid Already_paid)
    (link_not_active (Link_not_active Completed))
    |}]
;;

let%expect_test "an open-amount multi-use link with a cap" =
  let l = link ~usage:(Multi_use { max_uses = Some 2 }) () |> ok in
  print_refusal (pay l bob ~min:1);
  print_refusal (pay ~amount:(eur "0.00") l bob ~min:1);
  print_refusal (pay ~amount:(gbp "5.00") l bob ~min:1);
  print_refusal (pay ~amount:(gbp "5.00") ~currency:Money.Currency.gbp l bob ~min:1);
  print_refusal (pay ~amount:(eur "5.00") l alice ~min:1);
  [%expect
    {|
    (amount_required Amount_required)
    (amount_not_positive Amount_not_positive)
    (currency_mismatch (Currency_mismatch (expected EUR) (got GBP)))
    (currency_mismatch (Currency_mismatch (expected EUR) (got GBP)))
    (own_link Own_link)
    |}];
  let l = (pay ~amount:(eur "5.00") l bob ~min:1 |> ok).link in
  print_s [%message "" ~status:(l.status : Link_status.t) ~uses:(Link.uses l : int)];
  let step = pay ~amount:(eur "7.25") l carol ~min:2 |> ok in
  print_notices step.notices;
  print_s
    [%message
      ""
        ~status:(step.link.status : Link_status.t)
        ~collected:(Link.collected step.link : Money.Amount.t)];
  [%expect
    {|
    ((status Active) (uses 1))
    (link:l1:paid:carol (to_ alice))
    (link:l1:completed (to_ alice))
    ((status Completed) (collected "12.25 EUR"))
    |}]
;;

let%expect_test "a fixed amount cannot be changed by the payer" =
  let l = link ~amount:(eur "20.00") () |> ok in
  print_refusal (pay ~amount:(eur "19.99") l bob ~min:1);
  print_refusal (pay ~amount:(eur "20.00") l bob ~min:1);
  [%expect
    {|
    (amount_fixed Amount_fixed)
    accepted
    |}]
;;

let%expect_test "expiry and revocation" =
  let l = link ~amount:(eur "1.00") ~lifetime:One_day () |> ok in
  show l ~viewer:(Some alice) ~now:(after_day 1);
  print_refusal (pay l bob ~min:(24 * 60));
  print_refusal (Link.revoke l ~by:alice.customer ~now:(after_day 2));
  [%expect
    {|
    ((Unavailable Expired) ((own true) (paid false)))
    (link_not_active (Link_not_active Expired))
    (link_not_active (Link_not_active Expired))
    |}];
  print_refusal (Link.revoke l ~by:bob.customer ~now:t0);
  let revoked = Link.revoke l ~by:alice.customer ~now:(after_min 3) |> ok in
  show revoked ~viewer:None ~now:(after_min 4);
  print_refusal (pay revoked bob ~min:4);
  [%expect
    {|
    (only_owner_revokes Only_owner_revokes)
    ((Unavailable Revoked) ((own false) (paid false)))
    (link_not_active (Link_not_active Revoked))
    |}]
;;

let%expect_test "creation limits" =
  print_refusal (link ~usage:(Multi_use { max_uses = Some 0 }) ());
  print_refusal (link ~usage:(Multi_use { max_uses = Some 101 }) ());
  print_refusal (link ~usage:(Multi_use { max_uses = Some 100 }) ());
  print_refusal (link ~amount:(gbp "1.00") ());
  print_s [%sexp (List.map [ 1; 7; 30; 14 ] ~f:Link.Lifetime.of_days : Link.Lifetime.t option list)];
  [%expect
    {|
    (invalid_max_uses (Invalid_max_uses (max 100)))
    (invalid_max_uses (Invalid_max_uses (max 100)))
    accepted
    (currency_mismatch (Currency_mismatch (expected EUR) (got GBP)))
    ((One_day) (Seven_days) (Thirty_days) ())
    |}]
;;

(* The public view must never leak the owner's account, id or the payers. *)
let%test_unit "the public view carries only name, amount, currency and note" =
  let l = link ~amount:(eur "3.00") ~note:"x" () |> ok in
  let l = (pay l bob ~min:1 |> ok).link in
  let text =
    List.map [ t0; after_min 2 ] ~f:(fun now ->
      Sexp.to_string [%sexp (Link.public_view l ~viewer:None ~now : Link.Public.t * Link.Public.viewer)])
    |> String.concat
  in
  List.iter [ "customer:"; "alice"; "bob"; "l1" ] ~f:(fun secret ->
    [%test_pred: string] (fun text -> not (String.is_substring text ~substring:secret)) text)
;;

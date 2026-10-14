open! Core
open Requests_core
open Helpers

let request ?note ?(amount = eur "12.50") () =
  Request.create
    ~id:(Request_id.of_string "r1")
    ~requester:alice
    ~account:(account alice)
    ~payer:bob
    ~amount
    ?note:(Option.map note ~f:(fun s -> Note.of_string s |> Or_error.ok_exn))
    ~now:t0
    ()
;;

let pay_by (p : Party.t) : Request.Command.t =
  Pay { by = p.customer; from = account p; from_currency = Money.Currency.eur }
;;

let%expect_test "a new request notifies the payer and expires after 14 days" =
  let r, notices = request ~note:"  pizza   night " () |> ok in
  print_notices notices;
  print_s
    [%message
      ""
        ~note:(r.note : Note.t option)
        ~expires_at:(r.expires_at : Payments_core.Utc_time.t)];
  [%expect
    {|
    (request:r1:received (to_ bob))
    ((note ("pizza night")) (expires_at "2026-10-27 09:00:00Z"))
    |}];
  List.iter [ 0; 13; 14 ] ~f:(fun d ->
    printf
      "day %2d: %s\n"
      d
      (Request_status.to_string (Request.status r ~now:(after_day d))));
  [%expect {|
    day  0: pending
    day 13: pending
    day 14: expired
    |}]
;;

let%expect_test "creation refusals" =
  print_refusal (request ~amount:(eur "0.00") ());
  print_refusal
    (Request.create
       ~id:(Request_id.of_string "r2")
       ~requester:alice
       ~account:(account alice)
       ~payer:alice
       ~amount:(eur "1.00")
       ~now:t0
       ());
  [%expect
    {|
    (amount_not_positive Amount_not_positive)
    (request_to_self Request_to_self)
    |}]
;;

let%expect_test "paying returns the settlement and tells the requester" =
  let r, _ = request ~note:"pizza" () |> ok in
  let step = Request.apply r (pay_by bob) ~now:(after_min 5) |> ok in
  print_s [%sexp (step.request.status : Request_status.t)];
  print_notices step.notices;
  print_s [%sexp (step.settlement : Settlement.Instruction.t option)];
  print_s [%sexp (step.request.payment : Request.Payment.t option)];
  [%expect
    {|
    Paid
    (request:r1:paid (to_ alice))
    (((key request:r1) (payer ((customer bob) (name Bob)))
      (from customer:bob/eur) (payee ((customer alice) (name Alice)))
      (to_ customer:alice/eur) (amount "12.50 EUR") (reference pizza)))
    (((from customer:bob/eur) (key request:r1) (transfer request:r1/out)))
    |}];
  (* A paid request is final. *)
  print_refusal (Request.apply step.request (pay_by bob) ~now:(after_min 6));
  print_refusal
    (Request.apply step.request (Cancel { by = alice.customer }) ~now:(after_min 6));
  [%expect
    {|
    (not_pending (Not_pending Paid))
    (not_pending (Not_pending Paid))
    |}]
;;

let%expect_test "roles: who may do what" =
  let r, _ = request () |> ok in
  let now = after_min 30 in
  let try_ cmd = print_refusal (Request.apply r cmd ~now) in
  try_ (pay_by alice);
  try_ (pay_by carol);
  try_ (Decline { by = alice.customer });
  try_ (Cancel { by = bob.customer });
  try_ (Remind { by = bob.customer });
  try_ (Pay { by = bob.customer; from = account bob; from_currency = Money.Currency.gbp });
  [%expect
    {|
    (only_payer_pays Only_payer_pays)
    (not_a_party Not_a_party)
    (only_payer_declines Only_payer_declines)
    (only_requester_cancels Only_requester_cancels)
    (only_requester_reminds Only_requester_reminds)
    (currency_mismatch (Currency_mismatch (expected EUR) (got GBP)))
    |}];
  List.iter [ alice; bob; carol ] ~f:(fun p ->
    print_s
      [%message
        (Customer_id.to_string p.customer)
          ~_:(Request.role r p.customer : Request.Role.t option)
          ~_:(Request.actions r ~viewer:p.customer ~now : Request.Actions.t)]);
  [%expect
    {|
    (alice (Requester)
     ((can_pay false) (can_decline false) (can_cancel true) (can_remind true)))
    (bob (Payer)
     ((can_pay true) (can_decline true) (can_cancel false) (can_remind false)))
    (carol ()
     ((can_pay false) (can_decline false) (can_cancel false) (can_remind false)))
    |}]
;;

let%expect_test "decline and cancel notify the other side" =
  let r, _ = request () |> ok in
  let declined =
    Request.apply r (Decline { by = bob.customer }) ~now:(after_min 1) |> ok
  in
  print_notices declined.notices;
  let cancelled =
    Request.apply r (Cancel { by = alice.customer }) ~now:(after_min 1) |> ok
  in
  print_notices cancelled.notices;
  print_s
    [%message
      ""
        ~declined:(declined.request.status : Request_status.t)
        ~cancelled:(cancelled.request.status : Request_status.t)
        ~decided_at:(cancelled.request.decided_at : Payments_core.Utc_time.t option)];
  [%expect
    {|
    (request:r1:declined (to_ alice))
    (request:r1:cancelled (to_ bob))
    ((declined Declined) (cancelled Cancelled)
     (decided_at ("2026-10-13 09:01:00Z")))
    |}]
;;

let%expect_test "reminders: ten minutes apart, optional count limit" =
  let r, _ = request () |> ok in
  let remind ?policy r ~min =
    Request.apply ?policy r (Remind { by = alice.customer }) ~now:(after_min min)
  in
  print_refusal (remind r ~min:5);
  [%expect
    {| (reminder_too_soon (Reminder_too_soon (retry_at "2026-10-13 09:10:00Z"))) |}];
  let r1 = (remind r ~min:10 |> ok).request in
  print_refusal (remind r1 ~min:19);
  let step = remind r1 ~min:20 |> ok in
  print_notices step.notices;
  print_s [%message "" ~reminders:(step.request.reminders : int)];
  [%expect
    {|
    (reminder_too_soon (Reminder_too_soon (retry_at "2026-10-13 09:20:00Z")))
    (request:r1:reminder:2 (to_ bob))
    (reminders 2)
    |}];
  let policy = { Policy.default with max_reminders = Some 2 } in
  print_refusal (remind ~policy step.request ~min:60);
  print_s
    [%sexp
      (Request.next_reminder_at ~policy step.request ~now:(after_min 60)
       : Time_ns.Alternate_sexp.t option)];
  [%expect {|
    (reminder_limit_reached (Reminder_limit_reached (max 2)))
    ()
    |}]
;;

let%expect_test "expiry: read at once, marked by expire" =
  let r, _ = request () |> ok in
  print_s [%sexp (Request.expire r ~now:(after_day 13) |> Option.is_some : bool)];
  print_refusal (Request.apply r (pay_by bob) ~now:(after_day 14));
  let step = Request.expire r ~now:(after_day 20) |> Option.value_exn in
  print_notices step.notices;
  print_s
    [%message
      ""
        ~status:(step.request.status : Request_status.t)
        ~decided_at:(step.request.decided_at : Payments_core.Utc_time.t option)];
  print_s
    [%sexp (Request.expire step.request ~now:(after_day 21) |> Option.is_some : bool)];
  [%expect
    {|
    false
    (not_pending (Not_pending Expired))
    (request:r1:expired (to_ alice))
    ((status Expired) (decided_at ("2026-10-27 09:00:00Z")))
    false
    |}]
;;

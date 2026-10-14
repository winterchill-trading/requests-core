open! Core
open Requests_core
open Helpers

let share id (p : Party.t) amount = { Split.Share.request = Request_id.of_string id; payer = p; amount = eur amount }
let title = Note.of_string "Dinner" |> Or_error.ok_exn

let create ?(own = "10.00") shares =
  Split.create
    ~id:(Split_id.of_string "s1")
    ~owner:alice
    ~account:(account alice)
    ~title
    ~total:(eur "30.00")
    ~own_share:(eur own)
    ~shares
    ~now:t0
    ()
;;

let%expect_test "equal shares leave the remainder with the owner" =
  let show total others =
    print_s
      [%sexp
        (Split.equal_shares ~total:(eur total) ~others () : (Split.Equal_shares.t, Refusal.t) Result.t)]
  in
  show "10.00" 2;
  show "30.00" 2;
  show "0.05" 9;
  show "0.00" 1;
  show "10.00" 0;
  show "10.00" 21;
  [%expect
    {|
    (Ok ((own_share "3.34 EUR") (other_share "3.33 EUR") (remainder "0.01 EUR")))
    (Ok
     ((own_share "10.00 EUR") (other_share "10.00 EUR") (remainder "0.00 EUR")))
    (Ok ((own_share "0.05 EUR") (other_share "0.00 EUR") (remainder "0.05 EUR")))
    (Error Amount_not_positive)
    (Error No_participants)
    (Error (Too_many_participants (max 20)))
    |}]
;;

let%test_unit "equal shares add up and the remainder is less than one minor unit per person" =
  Quickcheck.test
    Quickcheck.Generator.(
      both (Int.gen_incl 1 1_000_000_000) (Int.gen_incl 1 Policy.default.max_split_participants))
    ~sexp_of:[%sexp_of: int * int]
    ~f:(fun (minor, others) ->
      let total = Money.Amount.of_minor_units_int Money.Currency.eur minor in
      let s = Split.equal_shares ~total ~others () |> ok in
      let units a = Money.Amount.minor_units_int a |> Option.value_exn in
      [%test_result: int] ~expect:minor (units s.own_share + (others * units s.other_share));
      [%test_result: int] ~expect:(units s.other_share + units s.remainder) (units s.own_share);
      [%test_pred: int] (fun r -> r >= 0 && r <= others) (units s.remainder))
;;

let%expect_test "creating a split creates one request per participant" =
  let c = create [ share "s1-1" bob "10.00"; share "s1-2" carol "10.00" ] |> ok in
  print_notices c.notices;
  List.iter c.requests ~f:(fun r ->
    print_s
      [%message
        ""
          ~payer:(r.payer.customer : Customer_id.t)
          ~amount:(r.amount : Money.Amount.t)
          ~split:(r.split : Split_id.t option)
          ~note:(r.note : Note.t option)]);
  [%expect
    {|
    (request:s1-1:received (to_ bob))
    (request:s1-2:received (to_ carol))
    ((payer bob) (amount "10.00 EUR") (split (s1)) (note (Dinner)))
    ((payer carol) (amount "10.00 EUR") (split (s1)) (note (Dinner)))
    |}]
;;

let%expect_test "creation refusals" =
  print_refusal (create []);
  print_refusal (create [ share "a" bob "10.00"; share "b" carol "9.99" ]);
  print_refusal (create [ share "a" bob "10.00"; share "b" bob "10.00" ]);
  print_refusal (create [ share "a" alice "10.00"; share "b" carol "10.00" ]);
  print_refusal (create ~own:"30.00" [ share "a" bob "0.00" ]);
  print_refusal
    (create [ share "a" bob "10.00"; { (share "b" carol "10.00") with amount = gbp "10.00" } ]);
  [%expect
    {|
    (no_participants No_participants)
    (shares_mismatch (Shares_mismatch (total "30.00 EUR") (sum "29.99 EUR")))
    (duplicate_participant (Duplicate_participant bob))
    (owner_in_participants Owner_in_participants)
    (amount_not_positive Amount_not_positive)
    (currency_mismatch (Currency_mismatch (expected EUR) (got GBP)))
    |}]
;;

let%expect_test "status follows the share requests" =
  let c = create [ share "s1-1" bob "10.00"; share "s1-2" carol "10.00" ] |> ok in
  let pay (r : Request.t) =
    (Request.apply
       r
       (Pay { by = r.payer.customer; from = account r.payer; from_currency = Money.Currency.eur })
       ~now:(after_min 1)
     |> ok)
      .request
  in
  let decline (r : Request.t) =
    (Request.apply r (Decline { by = r.payer.customer }) ~now:(after_min 1) |> ok).request
  in
  let show requests ~now =
    print_s [%sexp (Split.summary c.split ~requests ~now |> Or_error.ok_exn : Split.Summary.t)]
  in
  let r1, r2 =
    match c.requests with
    | [ a; b ] -> a, b
    | _ -> assert false
  in
  show [ r1; r2 ] ~now:t0;
  show [ pay r1; r2 ] ~now:t0;
  show [ pay r1; pay r2 ] ~now:t0;
  show [ pay r1; decline r2 ] ~now:t0;
  show [ pay r1; r2 ] ~now:(after_day 15);
  [%expect
    {|
    ((status Open) (participants 2) (paid 0) (collected "0.00 EUR")
     (outstanding "20.00 EUR"))
    ((status Open) (participants 2) (paid 1) (collected "10.00 EUR")
     (outstanding "10.00 EUR"))
    ((status Settled) (participants 2) (paid 2) (collected "20.00 EUR")
     (outstanding "0.00 EUR"))
    ((status Closed) (participants 2) (paid 1) (collected "10.00 EUR")
     (outstanding "0.00 EUR"))
    ((status Closed) (participants 2) (paid 1) (collected "10.00 EUR")
     (outstanding "0.00 EUR"))
    |}];
  print_s [%sexp (Split.summary c.split ~requests:[ r1 ] ~now:t0 |> Result.is_ok : bool)];
  [%expect {| false |}]
;;

let%expect_test "reminding a split reminds every pending share it may" =
  let c = create [ share "s1-1" bob "10.00"; share "s1-2" carol "10.00" ] |> ok in
  let remind ~by requests ~min =
    Split.remind c.split ~by ~requests ~now:(after_min min)
  in
  print_refusal (remind ~by:bob.customer c.requests ~min:30);
  print_refusal (remind ~by:alice.customer c.requests ~min:5);
  [%expect
    {|
    (only_requester_reminds Only_requester_reminds)
    (reminder_too_soon (Reminder_too_soon (retry_at "2026-10-13 09:10:00Z")))
    |}];
  let steps = remind ~by:alice.customer c.requests ~min:10 |> ok in
  List.iter steps ~f:(fun s -> print_notices s.notices);
  [%expect
    {|
    (request:s1-1:reminder:1 (to_ bob))
    (request:s1-2:reminder:1 (to_ carol))
    |}];
  let declined =
    List.map c.requests ~f:(fun r ->
      (Request.apply r (Decline { by = r.payer.customer }) ~now:(after_min 11) |> ok).request)
  in
  print_refusal (remind ~by:alice.customer declined ~min:30);
  [%expect {| (nothing_to_remind Nothing_to_remind) |}]
;;

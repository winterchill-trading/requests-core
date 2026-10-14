open! Core
open Requests_core
open Helpers

let link ~usage =
  Link.create
    ~id:(Link_id.of_string "l1")
    ~token:(Link_token.generate ())
    ~owner:alice
    ~account:(account alice)
    ~currency:Money.Currency.eur
    ~amount:(eur "5.00")
    ~lifetime:One_day
    ~usage
    ~now:t0
    ()
  |> ok
;;

let pay l (p : Party.t) =
  Link.pay
    l
    ~payer:p
    ~from:(account p)
    ~from_currency:Money.Currency.eur
    ~now:(after_min 1)
    ()
  |> ok
  |> fun (s : Link.Step.t) -> s.link
;;

let show l ~now =
  let r = Link.status_refusal l ~now in
  print_s
    [%message
      ""
        (r : Link.Status_refusal.t option)
        ~code:(Option.map r ~f:Link.Status_refusal.code : string option)
        ~as_refusal:(Option.map r ~f:Link.Status_refusal.to_refusal : Refusal.t option)]
;;

let%expect_test "status refusals without a payer, account or amount" =
  let single = link ~usage:Single_use in
  show single ~now:t0;
  show (pay single bob) ~now:(after_min 2);
  show single ~now:(after_day 1);
  show (Link.revoke single ~by:alice.customer ~now:(after_min 1) |> ok) ~now:(after_min 2);
  let capped = link ~usage:(Multi_use { max_uses = Some 2 }) in
  show (pay (pay capped bob) carol) ~now:(after_min 2);
  (* A completed link stays completed after its expiry. *)
  show (pay single bob) ~now:(after_day 2);
  [%expect
    {|
    ((r ()) (code ()) (as_refusal ()))
    ((r (Completed)) (code (link_completed))
     (as_refusal ((Link_not_active Completed))))
    ((r (Expired)) (code (link_expired))
     (as_refusal ((Link_not_active Expired))))
    ((r (Revoked)) (code (link_revoked))
     (as_refusal ((Link_not_active Revoked))))
    ((r ((Cap_reached (max_uses 2)))) (code (link_cap_reached))
     (as_refusal ((Link_not_active Completed))))
    ((r (Completed)) (code (link_completed))
     (as_refusal ((Link_not_active Completed))))
    |}]
;;

let%expect_test "check runs the payer checks of pay in its order" =
  let l = link ~usage:(Multi_use { max_uses = None }) in
  let paid = pay l bob in
  let check ?payer l ~now =
    print_refusal
      (Link.check l ?payer:(Option.map payer ~f:(fun (p : Party.t) -> p.customer)) ~now)
  in
  check l ~now:t0;
  check l ~payer:alice ~now:t0;
  check paid ~payer:bob ~now:(after_min 2);
  check paid ~payer:carol ~now:(after_min 2);
  (* Status comes before "already paid", as in [pay]. *)
  check paid ~payer:bob ~now:(after_day 1);
  check paid ~now:(after_day 1);
  [%expect
    {|
    accepted
    (own_link Own_link)
    (already_paid Already_paid)
    accepted
    (link_not_active (Link_not_active Expired))
    (link_not_active (Link_not_active Expired))
    |}]
;;

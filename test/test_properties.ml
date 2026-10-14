open! Core
open Requests_core
open Helpers

let parties = [ alice; bob; carol ]
let gen_party = Quickcheck.Generator.of_list parties

(* Commands arrive a random number of minutes apart, sometimes days, so the sequences
   cross the reminder gap and the 14-day expiry. *)
let gen_gap =
  Quickcheck.Generator.weighted_union
    [ 6., Int.gen_incl 0 15; 1., Int.gen_incl (60 * 24) (60 * 24 * 6) ]
;;

let gen_request_command =
  let open Quickcheck.Generator.Let_syntax in
  let%bind (p : Party.t) = gen_party in
  let%map kind = Int.gen_incl 0 4 in
  let by = p.customer in
  match kind with
  | 0 -> Request.Command.Pay { by; from = account p; from_currency = Money.Currency.eur }
  | 1 -> Pay { by; from = account p; from_currency = Money.Currency.gbp }
  | 2 -> Decline { by }
  | 3 -> Cancel { by }
  | _ -> Remind { by }
;;

let gen_script cmd = List.gen_with_length 12 (Quickcheck.Generator.both gen_gap cmd)

let%test_unit "request invariants hold for any command sequence" =
  let policy = { Policy.default with max_reminders = Some 3 } in
  Quickcheck.test
    (gen_script gen_request_command)
    ~sexp_of:[%sexp_of: (int * Request.Command.t) list]
    ~f:(fun script ->
      let r0, _ =
        Request.create
          ~policy
          ~id:(Request_id.of_string "r")
          ~requester:alice
          ~account:(account alice)
          ~payer:bob
          ~amount:(eur "10.00")
          ~now:t0
          ()
        |> ok
      in
      let _ =
        List.fold script ~init:(r0, 0, 0, None) ~f:(fun (r, minute, settlements, last_reminder) (gap, cmd) ->
          let minute = minute + gap in
          let now = after_min minute in
          let was_final = Request_status.is_final (Request.status r ~now) in
          match Request.apply ~policy r cmd ~now with
          | Error _ -> r, minute, settlements, last_reminder
          | Ok step ->
            let r' = step.request in
            (* Nothing leaves a final state. *)
            assert (not was_final);
            (* Exactly one notice, and never to the customer who acted. *)
            (match step.notices with
             | [ n ] ->
               (match cmd with
                | Pay { by; _ } | Decline { by } | Cancel { by } | Remind { by } ->
                  assert (not (Customer_id.equal n.recipient by)))
             | _ -> assert false);
            (* Paid exactly when a payment is recorded, and a settlement comes with it. *)
            [%test_result: bool]
              ~expect:(Request_status.equal r'.status Paid)
              (Option.is_some r'.payment);
            [%test_result: bool]
              ~expect:(Option.is_some step.settlement)
              (Request_status.equal r'.status Paid);
            [%test_result: bool]
              ~expect:(Request_status.is_final r'.status)
              (Option.is_some r'.decided_at);
            let settlements = settlements + Option.length step.settlement in
            assert (settlements <= 1);
            let last_reminder =
              if r'.reminders > r.reminders
              then (
                assert (r'.reminders = r.reminders + 1);
                assert (r'.reminders <= 3);
                let since = Option.value last_reminder ~default:r.created_at in
                assert (Time_ns.Span.( >= ) (Time_ns.diff now since) policy.reminder_gap);
                Some now)
              else last_reminder
            in
            r', minute, settlements, last_reminder)
      in
      ())
;;

type link_action =
  | Pay of Party.t * string option
  | Revoke of Party.t
[@@deriving sexp_of]

let gen_link_action =
  let open Quickcheck.Generator.Let_syntax in
  let customers =
    List.init 5 ~f:(fun i -> Party.create_exn ~customer:(customer (sprintf "c%d" i)) ~name:"C")
  in
  let%bind p = Quickcheck.Generator.of_list (alice :: customers) in
  let%bind kind = Int.gen_incl 0 9 in
  let%map amount = Quickcheck.Generator.of_list [ None; Some "0.00"; Some "2.50"; Some "5.00" ] in
  if kind = 0 then Revoke p else Pay (p, amount)
;;

let%test_unit "link invariants hold for any sequence of payments" =
  Quickcheck.test
    Quickcheck.Generator.(
      tuple3
        (of_list [ None; Some "5.00" ])
        (of_list Link.Usage.[ Single_use; Multi_use { max_uses = None }; Multi_use { max_uses = Some 3 } ])
        (gen_script gen_link_action))
    ~sexp_of:[%sexp_of: string option * Link.Usage.t * (int * link_action) list]
    ~f:(fun (amount, usage, script) ->
      let l0 =
        Link.create
          ~id:(Link_id.of_string "l")
          ~token:(Link_token.generate ())
          ~owner:alice
          ~account:(account alice)
          ~currency:Money.Currency.eur
          ?amount:(Option.map amount ~f:eur)
          ~lifetime:Seven_days
          ~usage
          ~now:t0
          ()
        |> ok
      in
      let cap =
        match usage with
        | Single_use -> Some 1
        | Multi_use { max_uses } -> max_uses
      in
      let final =
        List.fold script ~init:(l0, 0) ~f:(fun (l, minute) (gap, action) ->
          let minute = minute + gap in
          let now = after_min minute in
          let before = Link.status l ~now in
          match action with
          | Revoke p ->
            (match Link.revoke l ~by:p.customer ~now with
             | Ok l' ->
               assert (Link_status.equal before Active);
               assert (Link_status.equal l'.status Revoked);
               l', minute
             | Error _ -> l, minute)
          | Pay (p, given) ->
            (match
               Link.pay l ~payer:p ~from:(account p) ~from_currency:Money.Currency.eur
                 ?amount:(Option.map given ~f:eur) ~now ()
             with
             | Error _ -> l, minute
             | Ok step ->
               assert (Link_status.equal before Active);
               assert (not (Customer_id.equal p.customer alice.customer));
               assert (not (Link.has_paid l p.customer));
               assert (Money.Amount.is_positive step.settlement.amount);
               Option.iter l.amount ~f:(fun fixed ->
                 assert (Money.Amount.equal fixed step.settlement.amount));
               step.link, minute))
        |> fst
      in
      let uses = Link.uses final in
      Option.iter cap ~f:(fun cap -> assert (uses <= cap));
      [%test_result: bool]
        ~expect:(Option.exists cap ~f:(fun cap -> uses = cap))
        (Link_status.equal final.status Completed);
      let payers = List.map final.payments ~f:(fun p -> p.payer.customer) in
      assert (not (List.contains_dup payers ~compare:Customer_id.compare));
      [%test_result: Money.Amount.t]
        ~expect:
          (Money.Amount.sum Money.Currency.eur (List.map final.payments ~f:(fun p -> p.amount))
           |> Or_error.ok_exn)
        (Link.collected final);
      (* Nothing is paid at or after expiry. *)
      List.iter final.payments ~f:(fun p -> assert (Time_ns.( < ) p.at final.expires_at)))
;;

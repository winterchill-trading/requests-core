(* Two customers at one institution: Ada asks Ben for money, shares a payment link and
   splits a dinner bill. Every step is pure; this file plays the service, keeping the
   values in the in-memory store and the money in ledger balances. *)

open! Core
open Requests_core
module Store = Store_memory.Make (Monad.Ident)

let t0 = Time_ns.of_string_with_utc_offset "2026-10-13 18:00:00Z"
let at min = Time_ns.add t0 (Time_ns.Span.of_int_sec (60 * min))
let eur s = Money.Amount.of_decimal_string Money.Currency.eur s |> Or_error.ok_exn
let party id name = Party.create_exn ~customer:(Customer_id.of_string id) ~name
let ada = party "ada" "Ada"
let ben = party "ben" "Ben"
let cleo = party "cleo" "Cleo"

let account (p : Party.t) =
  Ledger.Account_id.of_string ("customer:" ^ Customer_id.to_string p.customer)
;;

let ok = function
  | Ok x -> x
  | Error r -> raise_s [%sexp (r : Refusal.t)]
;;

(* A ledger with the three customer accounts, the intraledger settlement account, and Ben
   and Cleo funded from outside. *)
let balances =
  let apply b event =
    Ledger.Balances.apply b { seq = Ledger.Balances.next_seq b; event } |> Or_error.ok_exn
  in
  let clearing = Ledger.Account_id.of_string "external:clearing" in
  let b =
    List.fold
      ((Ledger.Account.create ~allow_negative:true clearing Asset
        :: List.map [ ada; ben; cleo ] ~f:(fun p ->
          Ledger.Account.create (account p) Liability))
       @ Settlement.accounts [ Money.Currency.eur ])
      ~init:Ledger.Balances.empty
      ~f:(fun b a -> apply b (Account_opened a))
  in
  List.fold [ ben; cleo ] ~init:b ~f:(fun b p ->
    apply
      b
      (Posted
         (Ledger.Entry.create
            ~idempotency_key:(Ledger.Idempotency_key.of_string ("salary:" ^ p.name))
            ~kind:(Transfer "deposit")
            ~effective_at:t0
            ~recorded_at:t0
            [ Ledger.Posting.debit clearing (eur "100.00")
            ; Ledger.Posting.credit (account p) (eur "100.00")
            ]
          |> Or_error.ok_exn)))
;;

let balances = ref balances

(* What the service does with a settlement: check funds, book, apply. *)
let settle (i : Settlement.Instruction.t) ~now =
  ok (Settlement.check_funds !balances i);
  let booked =
    Settlement.book
      !balances
      i
      ~authorization:(Sca (Payments_core.Sca.Id.of_string "step-up-1"))
      ~at:now
    |> Or_error.ok_exn
  in
  balances := Payments_core.Booking.apply !balances booked.entries |> Or_error.ok_exn;
  printf
    "  booked %s: %s -> %s\n"
    (Ledger.Idempotency_key.to_string i.key)
    (Money.Amount.to_string i.amount)
    i.payee.name
;;

let show_notices store notices =
  Store.add_notices store notices;
  List.iter notices ~f:(fun n -> printf "  notice %s\n" (Notice.key n))
;;

let () =
  let store = Store.create () in
  print_endline "1. Ada asks Ben for 12.50 EUR";
  let r, notices =
    Request.create
      ~id:(Request_id.of_string "req-1")
      ~requester:ada
      ~account:(account ada)
      ~payer:ben
      ~amount:(eur "12.50")
      ~note:(Note.of_string "cinema" |> Or_error.ok_exn)
      ~now:t0
      ()
    |> ok
  in
  (match Store.insert_request store r with
   | `Inserted -> ()
   | `Exists _ -> assert false);
  show_notices store notices;
  print_endline "2. Ada reminds too early, then Ben pays";
  (match Request.apply r (Remind { by = ada.customer }) ~now:(at 3) with
   | Error refusal -> printf "  refused: %s\n" (Refusal.code refusal)
   | Ok _ -> assert false);
  let step =
    Request.apply
      r
      (Pay { by = ben.customer; from = account ben; from_currency = Money.Currency.eur })
      ~now:(at 4)
    |> ok
  in
  settle (Option.value_exn step.settlement) ~now:(at 4);
  (match Store.update_request store ~expected:r step.request with
   | `Updated -> ()
   | `Stale _ -> assert false);
  show_notices store step.notices;
  print_endline "3. Ada shares a link for concert tickets";
  let link =
    Link.create
      ~id:(Link_id.of_string "link-1")
      ~token:(Link_token.generate ())
      ~owner:ada
      ~account:(account ada)
      ~currency:Money.Currency.eur
      ~amount:(eur "30.00")
      ~note:(Note.of_string "concert" |> Or_error.ok_exn)
      ~usage:(Multi_use { max_uses = Some 2 })
      ~now:(at 5)
      ()
    |> ok
  in
  ignore (Store.insert_link store link : [ `Inserted | `Exists of Link.t | `Token_taken ]);
  (* The token itself is random; only its length is printed. *)
  printf "  token: %d characters\n" (String.length (Link_token.to_string link.token));
  let public, _ = Link.public_view link ~viewer:None ~now:(at 6) in
  print_s [%sexp (public : Link.Public.t)];
  let link =
    List.fold [ ben; cleo ] ~init:link ~f:(fun link payer ->
      let step =
        Link.pay
          link
          ~payer
          ~from:(account payer)
          ~from_currency:Money.Currency.eur
          ~now:(at 7)
          ()
        |> ok
      in
      settle step.settlement ~now:(at 7);
      show_notices store step.notices;
      step.link)
  in
  printf "  link is %s\n" (Link_status.to_string (Link.status link ~now:(at 8)));
  print_endline "4. Ada splits a 25.00 EUR dinner three ways";
  let shares = Split.equal_shares ~total:(eur "25.00") ~others:2 () |> ok in
  print_s [%sexp (shares : Split.Equal_shares.t)];
  let created =
    Split.create
      ~id:(Split_id.of_string "split-1")
      ~owner:ada
      ~account:(account ada)
      ~title:(Note.of_string "Dinner" |> Or_error.ok_exn)
      ~total:(eur "25.00")
      ~own_share:shares.own_share
      ~shares:
        [ { request = Request_id.of_string "split-1-ben"
          ; payer = ben
          ; amount = shares.other_share
          }
        ; { request = Request_id.of_string "split-1-cleo"
          ; payer = cleo
          ; amount = shares.other_share
          }
        ]
      ~now:(at 10)
      ()
    |> ok
  in
  ignore
    (Store.insert_split store created.split ~requests:created.requests
     : [ `Inserted | `Exists of Split.t | `Request_exists of Request_id.t ]);
  show_notices store created.notices;
  let ben_share = List.hd_exn created.requests in
  let step =
    Request.apply
      ben_share
      (Pay { by = ben.customer; from = account ben; from_currency = Money.Currency.eur })
      ~now:(at 11)
    |> ok
  in
  settle (Option.value_exn step.settlement) ~now:(at 11);
  ignore
    (Store.update_request store ~expected:ben_share step.request
     : [ `Updated | `Stale of Request.t option ]);
  let summary =
    Split.summary
      created.split
      ~requests:(Store.requests_of_split store created.split.id)
      ~now:(at 12)
    |> Or_error.ok_exn
  in
  print_s [%sexp (summary : Split.Summary.t)];
  print_endline "5. Balances";
  List.iter [ ada; ben; cleo ] ~f:(fun p ->
    printf
      "  %-5s %s\n"
      p.name
      (Money.Amount.to_string
         (Ledger.Balances.posted !balances (account p) Money.Currency.eur)));
  printf
    "  notices for Ada: %d\n"
    (List.length (Store.notices_for store ada.customer ~since:t0 ~limit:100))
;;

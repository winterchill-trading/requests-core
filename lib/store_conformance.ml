open! Core

module Make (M : Monad.S) (Store : Store.S with type 'a io := 'a M.t) = struct
  open M.Let_syntax

  let t0 = Time_ns.of_string_with_utc_offset "2026-01-05 12:00:00Z"
  let at min = Time_ns.add t0 (Time_ns.Span.of_int_sec (60 * min))
  let eur minor = Money.Amount.of_minor_units_int Money.Currency.eur minor

  let party id =
    Party.create_exn
      ~customer:(Customer_id.of_string ("conf-" ^ id))
      ~name:(String.capitalize id)
  ;;

  let owner = party "owner"
  let payer = party "payer"
  let other = party "other"

  let account (p : Party.t) =
    Ledger.Account_id.of_string ("conf:" ^ Customer_id.to_string p.customer)
  ;;

  let request ?split ~id ~min ~(payer : Party.t) () =
    match
      Request.create
        ~id:(Request_id.of_string ("conf-" ^ id))
        ~requester:owner
        ~account:(account owner)
        ~payer
        ~amount:(eur 1000)
        ?split
        ~now:(at min)
        ()
    with
    | Ok (r, _) -> r
    | Error refusal -> raise_s [%sexp (refusal : Refusal.t)]
  ;;

  let token n =
    Link_token.of_random_bytes (String.make Link_token.byte_length (Char.of_int_exn n))
    |> Or_error.ok_exn
  ;;

  let link ~id ~token ~min =
    match
      Link.create
        ~id:(Link_id.of_string ("conf-" ^ id))
        ~token
        ~owner
        ~account:(account owner)
        ~currency:Money.Currency.eur
        ~usage:(Multi_use { max_uses = None })
        ~now:(at min)
        ()
    with
    | Ok l -> l
    | Error refusal -> raise_s [%sexp (refusal : Refusal.t)]
  ;;

  let expect name ~equal ~sexp_of got expected =
    if equal got expected
    then Ok ()
    else
      Or_error.error_s
        [%message name ~got:(sexp_of got : Sexp.t) ~expected:(sexp_of expected : Sexp.t)]
  ;;

  let ids rs = List.map rs ~f:(fun (r : Request.t) -> Request_id.to_string r.id)

  let expect_ids name got expected =
    expect
      name
      ~equal:[%equal: string list]
      ~sexp_of:[%sexp_of: string list]
      (ids got)
      (List.map expected ~f:(( ^ ) "conf-"))
  ;;

  let ( >>=? ) x f =
    let%bind r = x in
    match r with
    | Ok () -> f ()
    | Error _ as e -> return e
  ;;

  let requests store =
    let r1 = request ~id:"r1" ~min:0 ~payer () in
    let r2 = request ~id:"r2" ~min:1 ~payer () in
    let r3 = request ~id:"r3" ~min:2 ~payer:other () in
    let%bind i1 = Store.insert_request store r1 in
    let%bind _ = Store.insert_request store r2 in
    let%bind _ = Store.insert_request store r3 in
    let%bind again = Store.insert_request store r1 in
    let paid =
      match
        Request.apply
          r1
          (Pay
             { by = payer.customer
             ; from = account payer
             ; from_currency = Money.Currency.eur
             })
          ~now:(at 5)
      with
      | Ok step -> step.request
      | Error refusal -> raise_s [%sexp (refusal : Refusal.t)]
    in
    let%bind u1 = Store.update_request store ~expected:r1 paid in
    let%bind u2 = Store.update_request store ~expected:r1 paid in
    let%bind found = Store.find_request store r1.id in
    let%bind outgoing = Store.requests_of store owner.customer ~side:Requester ~limit:2 in
    let%bind incoming = Store.requests_of store payer.customer ~side:Payer ~limit:10 in
    let%bind none = Store.requests_of store other.customer ~side:Requester ~limit:10 in
    let%bind due =
      Store.due_requests
        store
        ~now:(Time_ns.add (at 1) Policy.default.request_lifetime)
        ~limit:10
    in
    return
      (Or_error.combine_errors_unit
         [ expect
             "first insert"
             ~equal:Poly.equal
             ~sexp_of:(function
               | `Inserted -> [%sexp "Inserted"]
               | `Exists _ -> [%sexp "Exists"])
             i1
             `Inserted
         ; (match again with
            | `Exists r when Request.equal r r1 -> Ok ()
            | _ ->
              Or_error.error_string "second insert of a request id must return Exists")
         ; (match u1, u2 with
            | `Updated, `Stale (Some r) when Request.equal r paid -> Ok ()
            | _ ->
              Or_error.error_string
                "compare-and-set: first update wins, second sees the new value")
         ; expect
             "find after update"
             ~equal:[%equal: Request.t option]
             ~sexp_of:[%sexp_of: Request.t option]
             found
             (Some paid)
         ; expect_ids "outgoing, newest first, limited" outgoing [ "r3"; "r2" ]
         ; expect_ids "incoming" incoming [ "r2"; "r1" ]
         ; expect_ids "a payer has no outgoing" none []
         ; (* r1 is paid, so only the pending r2 (created a minute later than r1) and not
              r3 (two minutes) are due. *)
           expect_ids "due requests" due [ "r2" ]
         ])
  ;;

  let links store =
    let l1 = link ~id:"l1" ~token:(token 1) ~min:0 in
    let l2 = link ~id:"l2" ~token:(token 2) ~min:1 in
    let clash = link ~id:"l3" ~token:(token 1) ~min:2 in
    let%bind i1 = Store.insert_link store l1 in
    let%bind i2 = Store.insert_link store l2 in
    let%bind i3 = Store.insert_link store clash in
    let%bind again = Store.insert_link store l1 in
    let paid =
      match
        Link.pay
          l1
          ~payer
          ~from:(account payer)
          ~from_currency:Money.Currency.eur
          ~amount:(eur 500)
          ~now:(at 3)
          ()
      with
      | Ok step -> step.link
      | Error refusal -> raise_s [%sexp (refusal : Refusal.t)]
    in
    let%bind u1 = Store.update_link store ~expected:l1 paid in
    let%bind u2 = Store.update_link store ~expected:l1 paid in
    let%bind by_token = Store.find_link_by_token store (token 1) in
    let%bind missing = Store.find_link_by_token store (token 9) in
    let%bind mine = Store.links_of store owner.customer in
    let%bind l3 = Store.find_link store clash.id in
    return
      (Or_error.combine_errors_unit
         [ (match i1, i2, i3, again with
            | `Inserted, `Inserted, `Token_taken, `Exists l when Link.equal l l1 -> Ok ()
            | _ -> Or_error.error_string "link inserts: ids and tokens are unique")
         ; (match u1, u2 with
            | `Updated, `Stale (Some l) when Link.equal l paid -> Ok ()
            | _ -> Or_error.error_string "link compare-and-set")
         ; expect
             "find by token"
             ~equal:[%equal: Link.t option]
             ~sexp_of:[%sexp_of: Link.t option]
             by_token
             (Some paid)
         ; expect
             "unknown token"
             ~equal:[%equal: Link.t option]
             ~sexp_of:[%sexp_of: Link.t option]
             missing
             None
         ; expect
             "a refused link is not stored"
             ~equal:[%equal: Link.t option]
             ~sexp_of:[%sexp_of: Link.t option]
             l3
             None
         ; expect
             "links newest first"
             ~equal:[%equal: Link_id.t list]
             ~sexp_of:[%sexp_of: Link_id.t list]
             (List.map mine ~f:(fun (l : Link.t) -> l.id))
             [ l2.id; l1.id ]
         ])
  ;;

  let splits store =
    let split_id = Split_id.of_string "conf-s1" in
    let split ~id shares =
      match
        Split.create
          ~id
          ~owner
          ~account:(account owner)
          ~title:(Note.of_string "Conformance" |> Or_error.ok_exn)
          ~total:(eur 3000)
          ~own_share:(eur 1000)
          ~source:"conf-tx"
          ~shares:
            (List.map shares ~f:(fun (request, payer) ->
               { Split.Share.request = Request_id.of_string request
               ; payer
               ; amount = eur 1000
               }))
          ~now:(at 10)
          ()
      with
      | Ok c -> c
      | Error refusal -> raise_s [%sexp (refusal : Refusal.t)]
    in
    let created = split ~id:split_id [ "conf-s1-a", payer; "conf-s1-b", other ] in
    (* A split whose share reuses a stored request id must leave nothing behind. *)
    let bad_id = Split_id.of_string "conf-s2" in
    let bad = split ~id:bad_id [ "conf-s2-a", payer; "conf-r1", other ] in
    let%bind bad_insert = Store.insert_split store bad.split ~requests:bad.requests in
    let%bind bad_found = Store.find_split store bad_id in
    let%bind bad_share = Store.find_request store (Request_id.of_string "conf-s2-a") in
    let%bind i1 = Store.insert_split store created.split ~requests:created.requests in
    let%bind i2 = Store.insert_split store created.split ~requests:created.requests in
    let%bind shares = Store.requests_of_split store split_id in
    let%bind by_source = Store.splits_of store owner.customer ~source:"conf-tx" () in
    let%bind other_source = Store.splits_of store owner.customer ~source:"conf-none" () in
    return
      (Or_error.combine_errors_unit
         [ (match bad_insert, bad_found, bad_share with
            | `Request_exists id, None, None
              when String.equal (Request_id.to_string id) "conf-r1" -> Ok ()
            | _ ->
              Or_error.error_string
                "a split insert with a taken request id must write nothing")
         ; (match i1, i2 with
            | `Inserted, `Exists s when Split.equal s created.split -> Ok ()
            | _ -> Or_error.error_string "split insert once")
         ; expect
             "share requests"
             ~equal:[%equal: string list]
             ~sexp_of:[%sexp_of: string list]
             (List.sort (ids shares) ~compare:String.compare)
             [ "conf-s1-a"; "conf-s1-b" ]
         ; expect
             "splits by source"
             ~equal:[%equal: int]
             ~sexp_of:[%sexp_of: int]
             (List.length by_source)
             1
         ; expect
             "splits by another source"
             ~equal:[%equal: int]
             ~sexp_of:[%sexp_of: int]
             (List.length other_source)
             0
         ])
  ;;

  let notices store =
    let notice min key_request : Notice.t =
      { recipient = payer.customer
      ; at = at min
      ; event =
          Request_received
            { request = Request_id.of_string key_request
            ; from = owner
            ; amount = eur 100
            ; note = None
            }
      }
    in
    let n1 = notice 20 "conf-n1" in
    let n2 = notice 21 "conf-n2" in
    let%bind () = Store.add_notices store [ n1; n2 ] in
    (* The same key again, even with a later time, is not stored twice. *)
    let%bind () = Store.add_notices store [ { n1 with at = at 30 } ] in
    let%bind all = Store.notices_for store payer.customer ~since:(at 20) ~limit:10 in
    let%bind recent = Store.notices_for store payer.customer ~since:(at 21) ~limit:10 in
    let%bind one = Store.notices_for store payer.customer ~since:(at 0) ~limit:1 in
    return
      (expect
         "notices"
         ~equal:[%equal: Notice.t list list]
         ~sexp_of:[%sexp_of: Notice.t list list]
         [ all; recent; one ]
         [ [ n2; n1 ]; [ n2 ]; [ n2 ] ])
  ;;

  let check store =
    requests store
    >>=? fun () -> links store >>=? fun () -> splits store >>=? fun () -> notices store
  ;;
end

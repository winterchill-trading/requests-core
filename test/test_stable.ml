open! Core
open Requests_core
open Helpers

(* A changed digest means stored bytes no longer decode: add a Stable.V2 instead of
   editing V1, and keep V1 readable. *)
let%expect_test "stable bin_prot digests" =
  List.iter
    [ "Customer_id", [%bin_digest: Customer_id.Stable.V1.t]
    ; "Request_id", [%bin_digest: Request_id.Stable.V1.t]
    ; "Link_id", [%bin_digest: Link_id.Stable.V1.t]
    ; "Split_id", [%bin_digest: Split_id.Stable.V1.t]
    ; "Note", [%bin_digest: Note.Stable.V1.t]
    ; "Party", [%bin_digest: Party.Stable.V1.t]
    ; "Request_status", [%bin_digest: Request_status.Stable.V1.t]
    ; "Link_status", [%bin_digest: Link_status.Stable.V1.t]
    ; "Link_token", [%bin_digest: Link_token.Stable.V1.t]
    ; "Notice", [%bin_digest: Notice.Stable.V1.t]
    ; "Instruction", [%bin_digest: Settlement.Instruction.Stable.V1.t]
    ; "Request", [%bin_digest: Request.Stable.V1.t]
    ; "Link", [%bin_digest: Link.Stable.V1.t]
    ; "Split", [%bin_digest: Split.Stable.V1.t]
    ]
    ~f:(fun (name, digest) -> printf "%-15s %s\n" name digest);
  [%expect
    {|
    Customer_id     d9a8da25d5656b016fb4dbdc2e4197fb
    Request_id      d9a8da25d5656b016fb4dbdc2e4197fb
    Link_id         d9a8da25d5656b016fb4dbdc2e4197fb
    Split_id        d9a8da25d5656b016fb4dbdc2e4197fb
    Note            d9a8da25d5656b016fb4dbdc2e4197fb
    Party           d9b6f4a2e896ed2f1330e3187bb0bd59
    Request_status  2cb33ab7c326135c74bda6957c3d77a9
    Link_status     123d95b94225be4b9938895e6809cb63
    Link_token      d9a8da25d5656b016fb4dbdc2e4197fb
    Notice          e371220c01fa3333ebb62be8baf25ee9
    Instruction     a7d29518358b3461149cd396c7ddc813
    Request         810dc6c10004081ef05d7ecdc89cb980
    Link            8d0871f5a7be3a1651564aaebb1d2cb7
    Split           ab9b71ec19caa91463b97f8dec026518
    |}]
;;

let round_trip
  (type a)
  (module M : Binable.S with type t = a)
  ~(sexp_of : a -> Sexp.t)
  ~(of_sexp : Sexp.t -> a)
  ~equal
  (v : a)
  =
  let back = Binable.of_string (module M) (Binable.to_string (module M) v) in
  assert (equal back v);
  assert (equal (of_sexp (sexp_of v)) v)
;;

let%test_unit "requests, links, splits and notices round-trip" =
  let r, notices =
    Request.create
      ~id:(Request_id.of_string "r1")
      ~requester:alice
      ~account:(account alice)
      ~payer:bob
      ~amount:(eur "9.99")
      ~note:(Note.of_string "lunch" |> Or_error.ok_exn)
      ~now:t0
      ()
    |> ok
  in
  let step =
    Request.apply
      r
      (Pay { by = bob.customer; from = account bob; from_currency = Money.Currency.eur })
      ~now:(after_min 1)
    |> ok
  in
  let module R = Request.Stable.V1 in
  List.iter
    [ r; step.request ]
    ~f:(round_trip (module R) ~sexp_of:R.sexp_of_t ~of_sexp:R.t_of_sexp ~equal:R.equal);
  let module N = Notice.Stable.V1 in
  List.iter
    (notices @ step.notices)
    ~f:(round_trip (module N) ~sexp_of:N.sexp_of_t ~of_sexp:N.t_of_sexp ~equal:N.equal);
  let module I = Settlement.Instruction.Stable.V1 in
  round_trip
    (module I)
    ~sexp_of:I.sexp_of_t
    ~of_sexp:I.t_of_sexp
    ~equal:I.equal
    (Option.value_exn step.settlement);
  let l =
    Link.create
      ~id:(Link_id.of_string "l1")
      ~token:(Link_token.generate ())
      ~owner:alice
      ~account:(account alice)
      ~currency:Money.Currency.eur
      ~usage:(Multi_use { max_uses = Some 3 })
      ~now:t0
      ()
    |> ok
  in
  let paid =
    (Link.pay
       l
       ~payer:bob
       ~from:(account bob)
       ~from_currency:Money.Currency.eur
       ~amount:(eur "4.00")
       ~now:(after_min 2)
       ()
     |> ok)
      .link
  in
  let module L = Link.Stable.V1 in
  List.iter
    [ l; paid ]
    ~f:(round_trip (module L) ~sexp_of:L.sexp_of_t ~of_sexp:L.t_of_sexp ~equal:L.equal);
  let split =
    (Split.create
       ~id:(Split_id.of_string "s1")
       ~owner:alice
       ~account:(account alice)
       ~title:(Note.of_string "Taxi" |> Or_error.ok_exn)
       ~total:(eur "9.00")
       ~own_share:(eur "3.00")
       ~source:"tx-1"
       ~shares:
         [ { request = Request_id.of_string "s1-1"; payer = bob; amount = eur "3.00" }
         ; { request = Request_id.of_string "s1-2"; payer = carol; amount = eur "3.00" }
         ]
       ~now:t0
       ()
     |> ok)
      .split
  in
  let module S = Split.Stable.V1 in
  round_trip (module S) ~sexp_of:S.sexp_of_t ~of_sexp:S.t_of_sexp ~equal:S.equal split
;;

let%expect_test "decoding re-checks ids, notes and tokens" =
  let decode (type a) (module M : Binable.S with type t = a) s =
    Result.is_ok
      (Result.try_with (fun () ->
         Binable.of_string (module M) (Binable.to_string (module String) s)))
  in
  print_s
    [%sexp
      ([ decode (module Customer_id.Stable.V1) "ok-id"
       ; decode (module Customer_id.Stable.V1) "not ok"
       ; decode (module Note.Stable.V1) (String.make 36 'x')
       ; decode (module Link_token.Stable.V1) "short"
       ]
       : bool list)];
  [%expect {| (true false false false) |}]
;;

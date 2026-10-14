open! Core
module Utc_time = Payments_core.Utc_time

module Stable = struct
  module V1 = struct
    module Usage = struct
      type t =
        | Single_use
        | Multi_use of { max_uses : int option }
      [@@deriving bin_io, sexp, compare, equal]
    end

    module Payment = struct
      type t =
        { payer : Party.Stable.V1.t
        ; amount : Money.Amount.Stable.V1.t
        ; at : Utc_time.Stable.V1.t
        ; key : Ledger.Idempotency_key.Stable.V1.t
        ; transfer : Payments_core.Transfer.Id.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end

    type t =
      { id : Link_id.Stable.V1.t
      ; token : Link_token.Stable.V1.t
      ; owner : Party.Stable.V1.t
      ; account : Ledger.Account_id.Stable.V1.t
      ; currency : Money.Currency.Stable.V1.t
      ; amount : Money.Amount.Stable.V1.t option
      ; note : Note.Stable.V1.t option
      ; usage : Usage.t
      ; created_at : Utc_time.Stable.V1.t
      ; expires_at : Utc_time.Stable.V1.t
      ; status : Link_status.Stable.V1.t
      ; closed_at : Utc_time.Stable.V1.t option
      ; payments : Payment.t list
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

module Lifetime = struct
  type t =
    | One_day
    | Seven_days
    | Thirty_days
  [@@deriving sexp, compare, equal, enumerate]

  let default = Seven_days

  let days = function
    | One_day -> 1
    | Seven_days -> 7
    | Thirty_days -> 30
  ;;

  let to_span t = Time_ns.Span.of_day (Float.of_int (days t))
  let of_days n = List.find all ~f:(fun t -> days t = n)
end

let create
  ?(policy = Policy.default)
  ~id
  ~token
  ~owner
  ~account
  ~currency
  ?amount
  ?note
  ?(lifetime = Lifetime.default)
  ~usage
  ~now
  ()
  =
  let amount_ok =
    match amount with
    | None -> Ok ()
    | Some a when not (Money.Currency.equal (Money.Amount.currency a) currency) ->
      Error
        (Refusal.Currency_mismatch { expected = currency; got = Money.Amount.currency a })
    | Some a when not (Money.Amount.is_positive a) -> Error Refusal.Amount_not_positive
    | Some _ -> Ok ()
  in
  let usage_ok =
    match (usage : Usage.t) with
    | Single_use | Multi_use { max_uses = None } -> Ok ()
    | Multi_use { max_uses = Some n } ->
      if n >= 1 && n <= policy.max_link_uses
      then Ok ()
      else Error (Refusal.Invalid_max_uses { max = policy.max_link_uses })
  in
  match amount_ok, usage_ok with
  | Error e, _ | _, Error e -> Error e
  | Ok (), Ok () ->
    Ok
      { id
      ; token
      ; owner
      ; account
      ; currency
      ; amount
      ; note
      ; usage
      ; created_at = now
      ; expires_at = Time_ns.add now (Lifetime.to_span lifetime)
      ; status = Active
      ; closed_at = None
      ; payments = []
      }
;;

let status t ~now : Link_status.t =
  match t.status with
  | Active when Time_ns.( >= ) now t.expires_at -> Expired
  | s -> s
;;

let uses t = List.length t.payments

let collected t =
  List.fold t.payments ~init:(Money.Amount.zero t.currency) ~f:(fun acc p ->
    Money.Amount.add_exn acc p.amount)
;;

let has_paid t customer =
  List.exists t.payments ~f:(fun p -> Customer_id.equal p.payer.customer customer)
;;

module Step = struct
  type nonrec t =
    { link : t
    ; notices : Notice.t list
    ; settlement : Settlement.Instruction.t
    }
  [@@deriving sexp_of]
end

let is_last_use t ~uses =
  match t.usage with
  | Single_use -> true
  | Multi_use { max_uses = Some max } -> uses >= max
  | Multi_use { max_uses = None } -> false
;;

let chosen_amount t ~given : (Money.Amount.t, Refusal.t) Result.t =
  match t.amount, given with
  | Some fixed, None -> Ok fixed
  | Some fixed, Some a ->
    if Money.Amount.equal fixed a then Ok fixed else Error Amount_fixed
  | None, None -> Error Amount_required
  | None, Some a ->
    if not (Money.Currency.equal (Money.Amount.currency a) t.currency)
    then
      Error (Currency_mismatch { expected = t.currency; got = Money.Amount.currency a })
    else if not (Money.Amount.is_positive a)
    then Error Amount_not_positive
    else Ok a
;;

let pay t ~(payer : Party.t) ~from ~from_currency ?amount ~now () =
  let open Result.Let_syntax in
  let%bind () =
    if Customer_id.equal payer.customer t.owner.customer
    then Error Refusal.Own_link
    else Ok ()
  in
  let%bind () = if has_paid t payer.customer then Error Refusal.Already_paid else Ok () in
  let%bind () =
    match status t ~now with
    | Active -> Ok ()
    | s -> Error (Refusal.Link_not_active s)
  in
  let%bind () =
    if Money.Currency.equal from_currency t.currency
    then Ok ()
    else Error (Refusal.Currency_mismatch { expected = t.currency; got = from_currency })
  in
  let%bind amount = chosen_amount t ~given:amount in
  let%map settlement =
    Settlement.Instruction.for_link
      t.id
      ~payer
      ~from
      ~payee:t.owner
      ~to_:t.account
      ~amount
      ~note:t.note
    (* The amount was checked above, so this fails only on paying into the source account. *)
    |> Result.map_error ~f:(fun _ -> Refusal.Same_account)
  in
  let payment : Payment.t =
    { payer
    ; amount
    ; at = now
    ; key = settlement.key
    ; transfer = Settlement.outgoing_id settlement
    }
  in
  let payments = t.payments @ [ payment ] in
  let completed = is_last_use t ~uses:(List.length payments) in
  let link =
    if completed
    then { t with payments; status = Completed; closed_at = Some now }
    else { t with payments }
  in
  let notice event : Notice.t = { recipient = t.owner.customer; at = now; event } in
  let notices =
    notice (Link_paid { link = t.id; by = payer; amount })
    ::
    (if completed
     then [ notice (Link_completed { link = t.id; collected = collected link }) ]
     else [])
  in
  { Step.link; notices; settlement }
;;

let revoke t ~by ~now =
  if not (Customer_id.equal by t.owner.customer)
  then Error Refusal.Only_owner_revokes
  else (
    match status t ~now with
    | Active -> Ok { t with status = Revoked; closed_at = Some now }
    | s -> Error (Refusal.Link_not_active s))
;;

module Public = struct
  type t =
    | Available of
        { name : string
        ; amount : Money.Amount.t option
        ; currency : Money.Currency.t
        ; note : Note.t option
        }
    | Unavailable of Link_status.t
  [@@deriving sexp_of, compare, equal]

  type viewer =
    { own : bool
    ; paid : bool
    }
  [@@deriving sexp_of, compare, equal]
end

let public_view t ~viewer ~now =
  let view : Public.t =
    match status t ~now with
    | Active ->
      Available
        { name = t.owner.name; amount = t.amount; currency = t.currency; note = t.note }
    | s -> Unavailable s
  in
  let viewer : Public.viewer =
    match viewer with
    | None -> { own = false; paid = false }
    | Some c -> { own = Customer_id.equal c t.owner.customer; paid = has_paid t c }
  in
  view, viewer
;;

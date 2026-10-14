open! Core
module Transfer = Payments_core.Transfer
module Booking = Payments_core.Booking
module Beneficiary = Payments_core.Beneficiary

module Instruction = struct
  module Stable = struct
    module V1 = struct
      type t =
        { key : Ledger.Idempotency_key.Stable.V1.t
        ; payer : Party.Stable.V1.t
        ; from : Ledger.Account_id.Stable.V1.t
        ; payee : Party.Stable.V1.t
        ; to_ : Ledger.Account_id.Stable.V1.t
        ; amount : Money.Amount.Stable.V1.t
        ; reference : string
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1

  let create ~key ~payer ~from ~payee ~to_ ~amount ~note =
    let open Or_error.Let_syntax in
    let%bind key = Ledger.Idempotency_key.of_string_or_error key in
    let%bind () =
      if Money.Amount.is_positive amount
      then Ok ()
      else Or_error.error_s [%message "amount must be positive" (amount : Money.Amount.t)]
    in
    let%map () =
      if Ledger.Account_id.equal from to_
      then
        Or_error.error_s
          [%message "payer and payee accounts are the same" (from : Ledger.Account_id.t)]
      else Ok ()
    in
    let reference = Option.value_map note ~default:"" ~f:Note.to_string in
    { key; payer; from; payee; to_; amount; reference }
  ;;

  let for_request id ~payer ~from ~payee ~to_ ~amount ~note =
    create
      ~key:("request:" ^ Request_id.to_string id)
      ~payer
      ~from
      ~payee
      ~to_
      ~amount
      ~note
  ;;

  let for_link id ~(payer : Party.t) ~from ~payee ~to_ ~amount ~note =
    create
      ~key:
        (sprintf
           "link:%s:%s"
           (Link_id.to_string id)
           (Customer_id.to_string payer.customer))
      ~payer
      ~from
      ~payee
      ~to_
      ~amount
      ~note
  ;;
end

let transfer_id (i : Instruction.t) suffix =
  Transfer.Id.of_string (Ledger.Idempotency_key.to_string i.key ^ "/" ^ suffix)
;;

let outgoing_id i = transfer_id i "out"
let incoming_id i = transfer_id i "in"

let accounts ?(chart = Booking.Chart.default) currencies =
  Booking.Chart.accounts chart ~rails:[ Intraledger ] ~currencies
;;

let check_funds balances (i : Instruction.t) =
  let currency = Money.Amount.currency i.amount in
  let available = Ledger.Balances.available balances i.from currency in
  if Z.lt (Money.Amount.minor_units available) (Money.Amount.minor_units i.amount)
  then Error (Refusal.Insufficient_funds { available; required = i.amount })
  else Ok ()
;;

module Booked = struct
  type t =
    { outgoing : Transfer.t
    ; incoming : Transfer.t
    ; entries : Ledger.Entry.t list
    }
  [@@deriving sexp_of]
end

let authorize (t : Transfer.t) (authorization : Payments_core.Sca.Authorization.t) ~at =
  match authorization with
  | Sca challenge -> Transfer.require_sca t ~challenge ~at
  | Exempt exemption -> Transfer.exempt t ~exemption
;;

let book ?(chart = Booking.Chart.default) balances (i : Instruction.t) ~authorization ~at =
  let open Or_error.Let_syntax in
  (* Every leg uses the instruction key as its event id; Booking appends the leg name
     ([/hold], [/capture], [/deposit]), so the three entry keys differ but a retry
     reproduces them exactly. *)
  let event_id = Ledger.Idempotency_key.to_string i.key in
  let%bind beneficiary =
    Beneficiary.create
      ~id:
        (Beneficiary.Id.of_string ("customer:" ^ Customer_id.to_string i.payee.customer))
      ~owner:(Customer_id.to_string i.payer.customer)
      ~name:i.payee.name
      ~rail:Intraledger
      ~now:at
      (Ledger.Account_id.to_string i.to_)
  in
  let%bind draft =
    Transfer.draft
      ~id:(outgoing_id i)
      ~rail:Intraledger
      ~account:i.from
      ~beneficiary
      ~amount:i.amount
      ~reference:i.reference
      ~now:at
      ()
  in
  let%bind authorized = authorize draft authorization ~at in
  let%bind hold =
    Booking.transition chart balances authorized ~to_:Submitted ~event_id ~at
  in
  let%bind balances = Booking.apply balances hold in
  let%bind submitted = Transfer.submit authorized ~at () in
  let%bind capture =
    Booking.transition chart balances submitted ~to_:Settled ~event_id ~at
  in
  let%bind balances = Booking.apply balances capture in
  let%bind outgoing = Transfer.transition submitted ~to_:Settled ~at in
  let%bind incoming =
    Transfer.incoming
      ~id:(incoming_id i)
      ~rail:Intraledger
      ~account:i.to_
      ~from:
        (External { name = i.payer.name; detail = Ledger.Account_id.to_string i.from })
      ~amount:i.amount
      ~reference:i.reference
      ~status:Settled
      ~now:at
      ()
  in
  let%map deposit = Booking.created chart balances incoming ~event_id ~at in
  { Booked.outgoing; incoming; entries = hold @ capture @ deposit }
;;

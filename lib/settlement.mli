(** Moving the money when a request or a link is paid.

    Both customers hold accounts at the same institution, so a payment is an
    intraledger transfer booked through [payments-core]: an outgoing transfer from the
    payer (a hold, captured at once into the intraledger settlement account) and an
    incoming transfer to the payee (paid out of that settlement account). The settlement
    account nets to zero after every payment; going through it keeps each side's
    statement line a normal payment with its own transfer id.

    Every ledger entry's idempotency key derives from the {!Instruction.key}
    ([request:<id>] for a request, [link:<id>:<payer>] for a link payment), and the
    transfer ids from the key too, so booking the same instruction twice produces
    identical entries and the journal records them once. *)

open! Core

module Instruction : sig
  type t = private
    { key : Ledger.Idempotency_key.t (** scoped to the payer *)
    ; payer : Party.t
    ; from : Ledger.Account_id.t (** the payer's account *)
    ; payee : Party.t
    ; to_ : Ledger.Account_id.t (** the payee's account *)
    ; amount : Money.Amount.t (** positive *)
    ; reference : string (** the request's or link's note, or empty *)
    }
  [@@deriving sexp_of, compare, equal]

  (** Paying a request; the key is [request:<id>]. Fails on a non-positive amount or
      when both accounts are the same. *)
  val for_request
    :  Request_id.t
    -> payer:Party.t
    -> from:Ledger.Account_id.t
    -> payee:Party.t
    -> to_:Ledger.Account_id.t
    -> amount:Money.Amount.t
    -> note:Note.t option
    -> t Or_error.t

  (** Paying a link; the key is [link:<id>:<payer>], since each payer pays a link once. *)
  val for_link
    :  Link_id.t
    -> payer:Party.t
    -> from:Ledger.Account_id.t
    -> payee:Party.t
    -> to_:Ledger.Account_id.t
    -> amount:Money.Amount.t
    -> note:Note.t option
    -> t Or_error.t

  module Stable : sig
    module V1 : sig
      type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
    end
  end
end

(** [<key>/out]: the payer's outgoing transfer. *)
val outgoing_id : Instruction.t -> Payments_core.Transfer.Id.t

(** [<key>/in]: the payee's incoming transfer. *)
val incoming_id : Instruction.t -> Payments_core.Transfer.Id.t

(** The institution's accounts the bookings need in these currencies (the intraledger
    settlement account and the fee account of [chart], default
    [Payments_core.Booking.Chart.default]). Open them once. *)
val accounts
  :  ?chart:Payments_core.Booking.Chart.t
  -> Money.Currency.t list
  -> Ledger.Account.t list

(** [Insufficient_funds] when the payer's available balance is below the amount. Run it
    before {!book} to answer with a refusal rather than a ledger error. *)
val check_funds : Ledger.Balances.t -> Instruction.t -> (unit, Refusal.t) Result.t

module Booked : sig
  type t =
    { outgoing : Payments_core.Transfer.t (** settled *)
    ; incoming : Payments_core.Transfer.t (** settled *)
    ; entries : Ledger.Entry.t list
    (** hold, capture and deposit, in that order; append them together *)
    }
  [@@deriving sexp_of]
end

(** The two settled transfers and their entries, checked against [balances].
    [authorization] is how the payer authorised the payment (an SCA challenge the
    service verified, or an exemption); it is kept on the outgoing transfer and its
    entries. Fails like the ledger does (unknown account, insufficient funds); use
    {!check_funds} first for a typed refusal. Append [entries] with
    [Payments_core.Booking.post] (or [Ledger.Journal.append_linked]) so the three are
    booked together or not at all. *)
val book
  :  ?chart:Payments_core.Booking.Chart.t
  -> Ledger.Balances.t
  -> Instruction.t
  -> authorization:Payments_core.Sca.Authorization.t
  -> at:Time_ns.t
  -> Booked.t Or_error.t

(** A money request: one customer (the requester) asks another (the payer) for an
    amount, into one of the requester's accounts.

    The lifecycle is in {!Request_status}. Everything here is pure: each operation takes
    the current value and the time and returns the next value, the {!Notice}s to deliver
    and, for a payment, the {!Settlement.Instruction} to book. A service persists the
    new value, books the settlement and stores the notices in one transaction, or drops
    all three.

    A pending request reads as [Expired] as soon as its lifetime has passed ({!status}),
    whether or not {!expire} has been applied and stored yet. *)

open! Core

module Payment : sig
  (** How a paid request was paid. *)
  type t =
    { from : Ledger.Account_id.t (** the payer's account *)
    ; key : Ledger.Idempotency_key.t (** the settlement's idempotency key *)
    ; transfer : Payments_core.Transfer.Id.t (** the payer's outgoing transfer *)
    }
  [@@deriving sexp_of, compare, equal]
end

type t = private
  { id : Request_id.t
  ; requester : Party.t
  ; account : Ledger.Account_id.t (** the requester's account the money goes to *)
  ; payer : Party.t
  ; amount : Money.Amount.t (** positive *)
  ; note : Note.t option
  ; split : Split_id.t option (** the split this request is a share of, if any *)
  ; status : Request_status.t (** as stored; see {!status} for the current one *)
  ; created_at : Payments_core.Utc_time.t
  ; expires_at : Payments_core.Utc_time.t
  ; reminders : int (** reminders sent so far *)
  ; last_reminded_at : Payments_core.Utc_time.t option
  ; decided_at : Payments_core.Utc_time.t option
  (** when it was paid, declined, cancelled or expired *)
  ; payment : Payment.t option (** set once paid *)
  }
[@@deriving sexp_of, compare, equal]

(** A new pending request, and the notice telling the payer. [expires_at] is [now] plus
    the policy's request lifetime. Refuses a non-positive amount and a request to
    oneself. *)
val create
  :  ?policy:Policy.t
  -> id:Request_id.t
  -> requester:Party.t
  -> account:Ledger.Account_id.t
  -> payer:Party.t
  -> amount:Money.Amount.t
  -> ?note:Note.t
  -> ?split:Split_id.t
  -> now:Time_ns.t
  -> unit
  -> (t * Notice.t list, Refusal.t) Result.t

(** The status at [now]: [Expired] for a stored [Pending] past [expires_at]. *)
val status : t -> now:Time_ns.t -> Request_status.t

module Role : sig
  type t =
    | Requester
    | Payer
  [@@deriving sexp_of, compare, equal]
end

(** The customer's side of the request; [None] for anyone else, who should not see it. *)
val role : t -> Customer_id.t -> Role.t option

module Command : sig
  type t =
    | Pay of
        { by : Customer_id.t
        ; from : Ledger.Account_id.t (** one of the payer's accounts *)
        ; from_currency : Money.Currency.t (** that account's currency *)
        }
    | Decline of { by : Customer_id.t }
    | Cancel of { by : Customer_id.t }
    | Remind of { by : Customer_id.t }
  [@@deriving sexp_of, compare, equal]
end

module Step : sig
  type nonrec t =
    { request : t
    ; notices : Notice.t list
    ; settlement : Settlement.Instruction.t option (** only for [Pay] *)
    }
  [@@deriving sexp_of]
end

(** Applies a command at [now]. The checks, in order: the caller is a party
    ([Not_a_party]); the caller has the right role ([Only_payer_pays], ...); the request
    is pending at [now] ([Not_pending]); then, for [Pay], the account's currency
    ([Currency_mismatch]) and, for [Remind], the count limit and the gap since the last
    reminder (or since creation). [Pay] moves to [Paid] and returns the settlement to
    book; if the booking fails the caller drops the step. *)
val apply
  :  ?policy:Policy.t
  -> t
  -> Command.t
  -> now:Time_ns.t
  -> (Step.t, Refusal.t) Result.t

(** Marks a request that has run out as [Expired] (stamped at its [expires_at]) and
    tells the requester. [None] when the request is final or not yet due. *)
val expire : t -> now:Time_ns.t -> Step.t option

(** When the requester may send the next reminder: [None] once the count limit is
    reached or the request is no longer pending. *)
val next_reminder_at : ?policy:Policy.t -> t -> now:Time_ns.t -> Time_ns.t option

module Actions : sig
  (** What a viewer may do now, for showing or hiding buttons. *)
  type t =
    { can_pay : bool
    ; can_decline : bool
    ; can_cancel : bool
    ; can_remind : bool
    }
  [@@deriving sexp_of, compare, equal]
end

val actions : ?policy:Policy.t -> t -> viewer:Customer_id.t -> now:Time_ns.t -> Actions.t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end

(** A payment link: a customer shares a token, and other customers of the institution pay
    into one of the owner's accounts through it.

    A link is single-use (completed after one payment) or multi-use (optionally capped at
    a number of payments). Its amount is fixed, or left to each payer. Each payer pays a
    link at most once, the owner cannot pay their own link, and a link lives 1, 7 or 30
    days. The states are in {!Link_status}; an active link past its expiry reads as
    [Expired] at once.

    Strangers see a link only through {!public_view}, which shows the owner's display
    name, the amount and the note while the link can be paid, and only the reason once it
    cannot. *)

open! Core

module Usage : sig
  type t =
    | Single_use
    | Multi_use of { max_uses : int option (** [None]: unlimited until expiry *) }
  [@@deriving sexp, compare, equal]
end

module Lifetime : sig
  type t =
    | One_day
    | Seven_days
    | Thirty_days
  [@@deriving sexp, compare, equal, enumerate]

  (** [Seven_days]. *)
  val default : t

  val to_span : t -> Time_ns.Span.t

  (** [Some] for 1, 7 or 30. *)
  val of_days : int -> t option
end

module Payment : sig
  (** One payment made through the link. *)
  type t =
    { payer : Party.t
    ; amount : Money.Amount.t
    ; at : Payments_core.Utc_time.t
    ; key : Ledger.Idempotency_key.t (** the settlement's idempotency key *)
    ; transfer : Payments_core.Transfer.Id.t (** the payer's outgoing transfer *)
    }
  [@@deriving sexp_of, compare, equal]
end

type t = private
  { id : Link_id.t
  ; token : Link_token.t
  ; owner : Party.t
  ; account : Ledger.Account_id.t (** the owner's account the money goes to *)
  ; currency : Money.Currency.t (** the account's currency *)
  ; amount : Money.Amount.t option (** [None]: each payer chooses *)
  ; note : Note.t option
  ; usage : Usage.t
  ; created_at : Payments_core.Utc_time.t
  ; expires_at : Payments_core.Utc_time.t
  ; status : Link_status.t (** as stored: never [Expired]; see {!val-status} *)
  ; closed_at : Payments_core.Utc_time.t option (** when completed or revoked *)
  ; payments : Payment.t list (** oldest first *)
  }
[@@deriving sexp_of, compare, equal]

(** A new active link. Refuses an amount that is not positive or not in [currency], and a
    cap outside [1, policy.max_link_uses]. *)
val create
  :  ?policy:Policy.t
  -> id:Link_id.t
  -> token:Link_token.t
  -> owner:Party.t
  -> account:Ledger.Account_id.t
  -> currency:Money.Currency.t
  -> ?amount:Money.Amount.t
  -> ?note:Note.t
  -> ?lifetime:Lifetime.t (** default {!Lifetime.default} *)
  -> usage:Usage.t
  -> now:Time_ns.t
  -> unit
  -> (t, Refusal.t) Result.t

(** The status at [now]: [Expired] for a stored [Active] at or past [expires_at]. *)
val status : t -> now:Time_ns.t -> Link_status.t

(** Payments made so far. *)
val uses : t -> int

(** The sum of the payments, in the link's currency. *)
val collected : t -> Money.Amount.t

(** Whether [customer] has paid this link. *)
val has_paid : t -> Customer_id.t -> bool

module Step : sig
  type nonrec t =
    { link : t
    ; notices : Notice.t list
    ; settlement : Settlement.Instruction.t
    }
  [@@deriving sexp_of]
end

(** A payment by [payer] from [from]. Checks, in order: the payer is not the owner
    ([Own_link]); the link is active at [now] ([Link_not_active], so a revoked, expired or
    completed link is reported as such even to a payer who paid it); the payer has not
    paid before ([Already_paid]); the account is in the link's currency
    ([Currency_mismatch]); then the amount: a fixed link takes no amount or the same one
    ([Amount_fixed]), an open link needs a positive one ([Amount_required],
    [Amount_not_positive]). The payment is recorded at once and the link completes when it
    reaches its cap; book the returned settlement in the same transaction. *)
val pay
  :  t
  -> payer:Party.t
  -> from:Ledger.Account_id.t
  -> from_currency:Money.Currency.t
  -> ?amount:Money.Amount.t
  -> now:Time_ns.t
  -> unit
  -> (Step.t, Refusal.t) Result.t

(** Revokes an active link; only the owner may. *)
val revoke : t -> by:Customer_id.t -> now:Time_ns.t -> (t, Refusal.t) Result.t

module Public : sig
  (** What anyone holding the token sees. *)
  type t =
    | Available of
        { name : string (** the owner's display name *)
        ; amount : Money.Amount.t option (** [None]: the payer chooses *)
        ; currency : Money.Currency.t
        ; note : Note.t option
        }
    | Unavailable of Link_status.t (** [Completed], [Revoked] or [Expired] *)
  [@@deriving sexp_of, compare, equal]

  (** For a signed-in viewer: whether the link is theirs and whether they paid it. Both
      are [false] for an anonymous viewer. *)
  type viewer =
    { own : bool
    ; paid : bool
    }
  [@@deriving sexp_of, compare, equal]
end

val public_view
  :  t
  -> viewer:Customer_id.t option
  -> now:Time_ns.t
  -> Public.t * Public.viewer

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end

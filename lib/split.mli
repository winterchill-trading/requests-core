(** A bill split: the owner paid a shared expense and asks each participant for their
    share. Each share is an ordinary {!Request} tagged with the split's id, so it is
    paid, declined, cancelled, reminded and expired like any other request; the split
    itself only records the plan and derives its status from the shares:

    - [Open] while any share is pending;
    - [Settled] when every share was paid;
    - [Closed] when none is pending but not all were paid.

    For an equal split, {!equal_shares} gives each participant the total divided by the
    number of people, rounded down to the minor unit, and leaves the remainder with the
    owner, who already paid the whole bill. *)

open! Core

module Equal_shares : sig
  type t =
    { own_share : Money.Amount.t (** [other_share + remainder] *)
    ; other_share : Money.Amount.t (** what each participant is asked for *)
    ; remainder : Money.Amount.t (** the minor units that do not divide evenly *)
    }
  [@@deriving sexp_of, compare, equal]
end

(** Divides [total] between the owner and [others] participants. Refuses a non-positive
    total and fewer than one or more than [policy.max_split_participants]
    participants. When the total has fewer minor units than there are people,
    [other_share] is zero and {!create} refuses such shares. *)
val equal_shares
  :  ?policy:Policy.t
  -> total:Money.Amount.t
  -> others:int
  -> unit
  -> (Equal_shares.t, Refusal.t) Result.t

module Share : sig
  type t =
    { request : Request_id.t
    ; payer : Party.t
    ; amount : Money.Amount.t
    }
  [@@deriving sexp_of, compare, equal]
end

type t = private
  { id : Split_id.t
  ; owner : Party.t
  ; account : Ledger.Account_id.t (** the owner's account the shares are paid into *)
  ; title : Note.t
  ; total : Money.Amount.t
  ; own_share : Money.Amount.t
  ; source : string option
  (** the owner's ledger entry or transaction the bill came from, if any *)
  ; shares : Share.t list (** in the order given *)
  ; created_at : Payments_core.Utc_time.t
  }
[@@deriving sexp_of, compare, equal]

module Created : sig
  type nonrec t =
    { split : t
    ; requests : Request.t list (** one per share, in order *)
    ; notices : Notice.t list (** one per participant *)
    }
  [@@deriving sexp_of]
end

(** A split and its requests. Refuses: a non-positive total; no participants or more
    than [policy.max_split_participants]; the owner as a participant; the same customer
    twice; a share that is not positive or not in the total's currency; a negative own
    share; and shares (the owner's included) that do not add up to the total. *)
val create
  :  ?policy:Policy.t
  -> id:Split_id.t
  -> owner:Party.t
  -> account:Ledger.Account_id.t
  -> title:Note.t
  -> total:Money.Amount.t
  -> own_share:Money.Amount.t
  -> ?source:string
  -> shares:Share.t list
  -> now:Time_ns.t
  -> unit
  -> (Created.t, Refusal.t) Result.t

module Status : sig
  type t =
    | Open
    | Settled
    | Closed
  [@@deriving sexp, compare, equal, enumerate]

  (** The rule above, over the shares' request statuses. An empty list is [Settled]. *)
  val of_shares : Request_status.t list -> t
end

module Summary : sig
  type t =
    { status : Status.t
    ; participants : int
    ; paid : int (** shares paid *)
    ; collected : Money.Amount.t (** sum of the paid shares *)
    ; outstanding : Money.Amount.t (** sum of the shares still pending *)
    }
  [@@deriving sexp_of, compare, equal]
end

(** The split's state from its share requests at [now] (expiry is read as with
    {!Request.status}). Fails when a share's request is missing from [requests]. *)
val summary : t -> requests:Request.t list -> now:Time_ns.t -> Summary.t Or_error.t

(** Reminds every pending share that may be reminded now; the steps are the requests'
    own reminder steps. Refuses a caller other than the owner, a split with nothing
    pending ([Nothing_to_remind]), and, when no pending share may be reminded yet, gives
    the refusal of the one that becomes remindable first. *)
val remind
  :  ?policy:Policy.t
  -> t
  -> by:Customer_id.t
  -> requests:Request.t list
  -> now:Time_ns.t
  -> (Request.Step.t list, Refusal.t) Result.t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end

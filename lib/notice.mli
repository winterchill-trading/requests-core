(** Something a customer should hear about, as a value. The library never sends
    anything: each transition returns its notices and the service renders and delivers
    them (an activity feed, a push message, an e-mail) in the recipient's language.

    {!key} is unique per notice and stable across retries, so a service can store
    notices idempotently next to the state change that produced them. *)

open! Core

module Event : sig
  type t =
    | Request_received of
        { request : Request_id.t
        ; from : Party.t
        ; amount : Money.Amount.t
        ; note : Note.t option
        } (** to the payer *)
    | Request_reminder of
        { request : Request_id.t
        ; from : Party.t
        ; amount : Money.Amount.t
        ; note : Note.t option
        ; number : int (** 1 for the first reminder *)
        } (** to the payer *)
    | Request_paid of
        { request : Request_id.t
        ; by : Party.t
        ; amount : Money.Amount.t
        } (** to the requester *)
    | Request_declined of
        { request : Request_id.t
        ; by : Party.t
        ; amount : Money.Amount.t
        } (** to the requester *)
    | Request_cancelled of
        { request : Request_id.t
        ; by : Party.t
        ; amount : Money.Amount.t
        } (** to the payer *)
    | Request_expired of
        { request : Request_id.t
        ; payer : Party.t
        ; amount : Money.Amount.t
        } (** to the requester *)
    | Link_paid of
        { link : Link_id.t
        ; by : Party.t
        ; amount : Money.Amount.t
        } (** to the link's owner *)
    | Link_completed of
        { link : Link_id.t
        ; collected : Money.Amount.t
        } (** to the link's owner, after the last allowed payment *)
  [@@deriving sexp_of, compare, equal]
end

type t =
  { recipient : Customer_id.t
  ; at : Payments_core.Utc_time.t
  ; event : Event.t
  }
[@@deriving sexp_of, compare, equal]

(** [request:<id>:received], [request:<id>:reminder:<n>], [link:<id>:paid:<payer>], ... *)
val key : t -> string

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end

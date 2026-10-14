(** The limits a service chooses. {!default} holds common retail values; every
    function that needs a limit takes the policy explicitly, so tests and different
    markets can set their own. *)

open! Core

type t =
  { request_lifetime : Time_ns.Span.t
  (** how long a request stays payable; after it the request reads as expired *)
  ; reminder_gap : Time_ns.Span.t
  (** minimum time between two reminders of one request (counted from the request's
      creation for the first one) *)
  ; max_reminders : int option (** reminders per request; [None] for no count limit *)
  ; max_link_uses : int (** upper bound a multi-use link may set for its payments *)
  ; max_split_participants : int (** people a split may ask, the requester excluded *)
  }
[@@deriving sexp_of, compare, equal]

(** 14 days, 10 minutes between reminders and no count limit, links of up to 100 uses,
    splits of up to 20 participants. *)
val default : t

(** Fails on a non-positive lifetime or limit, or a negative reminder gap (zero turns
    the throttle off). *)
val check : t -> unit Or_error.t

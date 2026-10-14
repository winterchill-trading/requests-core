(** Where requests, links, splits and notices live. Libraries never persist: a service
    implements this signature over its database, and {!Store_memory} serves tests,
    examples and offline modes. {!Store_conformance} checks an implementation.

    Writes are inserts that are atomic on their keys and compare-and-set updates, so two
    workers acting on the same request or link cannot both succeed: the loser re-reads,
    re-applies the command to the fresh value (which usually refuses it) and tries again.
    The ledger journal is not here; a service books {!Settlement} entries in the same
    transaction as the update that produced them, or outside it with the settlement key as
    the guard against booking twice. *)

open! Core

module type S = sig
  (** The service's effect: [Deferred.t] over a database, [Monad.Ident] in memory. *)
  type 'a io

  type t

  (** {2 Requests} *)

  (** Atomic on the id: [`Exists] returns the stored request and writes nothing. *)
  val insert_request : t -> Request.t -> [ `Inserted | `Exists of Request.t ] io

  (** Compare-and-set: replaces [expected] with [next] (same id) only if the stored value
      still equals [expected]; otherwise returns what is stored ([None] when the request
      does not exist) and writes nothing. *)
  val update_request
    :  t
    -> expected:Request.t
    -> Request.t
    -> [ `Updated | `Stale of Request.t option ] io

  val find_request : t -> Request_id.t -> Request.t option io

  (** The customer's requests on one side, newest first (by creation time, then id), at
      most [limit]. *)
  val requests_of
    :  t
    -> Customer_id.t
    -> side:Request.Role.t
    -> limit:int
    -> Request.t list io

  (** The share requests of a split, in no particular order. *)
  val requests_of_split : t -> Split_id.t -> Request.t list io

  (** Requests stored [Pending] whose [expires_at] is at or before [now], oldest expiry
      first, at most [limit]: the work of an expiry sweep. *)
  val due_requests : t -> now:Time_ns.t -> limit:int -> Request.t list io

  (** {2 Payment links} *)

  (** Atomic on both the id and the token. *)
  val insert_link : t -> Link.t -> [ `Inserted | `Exists of Link.t | `Token_taken ] io

  (** Compare-and-set, as {!update_request}. Two payers racing on one link both read the
      same value; one update wins and the other retries on the fresh value, so a cap or
      the one-payment-per-payer rule cannot be passed by a race. *)
  val update_link
    :  t
    -> expected:Link.t
    -> Link.t
    -> [ `Updated | `Stale of Link.t option ] io

  val find_link : t -> Link_id.t -> Link.t option io
  val find_link_by_token : t -> Link_token.t -> Link.t option io

  (** The owner's links, newest first. *)
  val links_of : t -> Customer_id.t -> Link.t list io

  (** {2 Splits} *)

  (** Inserts the split and its share requests together, all or nothing. [`Exists] returns
      the stored split. A share request whose id is already taken makes the whole insert
      fail with [`Request_exists]. *)
  val insert_split
    :  t
    -> Split.t
    -> requests:Request.t list
    -> [ `Inserted | `Exists of Split.t | `Request_exists of Request_id.t ] io

  val find_split : t -> Split_id.t -> Split.t option io

  (** The owner's splits, newest first; with [source], only those for that source. *)
  val splits_of : t -> Customer_id.t -> ?source:string -> unit -> Split.t list io

  (** {2 Notices} *)

  (** Stores notices, skipping any whose {!Notice.key} is already stored. *)
  val add_notices : t -> Notice.t list -> unit io

  (** The recipient's notices at or after [since], newest first, at most [limit]. *)
  val notices_for : t -> Customer_id.t -> since:Time_ns.t -> limit:int -> Notice.t list io
end

(** Scenarios every {!Store.S} implementation must pass: insert-once on ids and tokens,
    compare-and-set updates, listing order and limits, the expiry sweep query, split
    inserts that are all or nothing, and notice de-duplication. A service runs them
    against its database store in its own test suite, next to {!Store_memory}.

    Give it a fresh, empty store; the scenarios use ids starting with [conf-]. *)

open! Core

module Make (M : Monad.S) (Store : Store.S with type 'a io := 'a M.t) : sig
  (** [Ok ()] when every scenario passes, otherwise the first difference. *)
  val check : Store.t -> unit Or_error.t M.t
end

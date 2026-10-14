(** Shared fixtures: a fixed clock, three customers with EUR accounts, amounts. *)

open! Core
open Requests_core

(** 2026-10-13 09:00:00Z. *)
val t0 : Time_ns.t

val after_min : int -> Time_ns.t
val after_day : int -> Time_ns.t
val eur : string -> Money.Amount.t
val gbp : string -> Money.Amount.t
val customer : string -> Customer_id.t
val alice : Party.t
val bob : Party.t
val carol : Party.t
val account : Party.t -> Ledger.Account_id.t
val ok : ('a, Refusal.t) Result.t -> 'a
val print_refusal : ('a, Refusal.t) Result.t -> unit
val print_notices : Notice.t list -> unit

(** Balances with an EUR account for each party, the intraledger settlement accounts, and
    each party funded with the given amount from an external clearing account. *)
val ledger : (Party.t * string) list -> Ledger.Balances.t

val print_entries : Ledger.Entry.t list -> unit
val print_balances : Ledger.Balances.t -> Ledger.Account_id.t list -> unit

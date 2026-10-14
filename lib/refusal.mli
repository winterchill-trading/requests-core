(** Why an operation was refused. Every refusal is an expected business outcome, not a
    bug: a service maps it to its own error code and message, and {!code} gives a stable
    snake-case name to start from. *)

open! Core

type t =
  | Amount_not_positive
  | Currency_mismatch of
      { expected : Money.Currency.t
      ; got : Money.Currency.t
      }
  | Request_to_self (** a customer asked themselves for money *)
  | Not_a_party (** the caller is neither side of the request *)
  | Only_payer_pays
  | Only_payer_declines
  | Only_requester_cancels
  | Only_requester_reminds
  | Not_pending of Request_status.t (** the request is already final *)
  | Reminder_too_soon of { retry_at : Payments_core.Utc_time.t }
  | Reminder_limit_reached of { max : int }
  | Own_link (** the link's owner tried to pay it *)
  | Already_paid (** this payer has paid this link before *)
  | Link_not_active of Link_status.t
  | Only_owner_revokes
  | Amount_required (** the link leaves the amount to the payer, who gave none *)
  | Amount_fixed (** the link has a fixed amount and the payer sent another *)
  | Invalid_max_uses of { max : int }
  | Max_uses_on_single_use
  | No_participants
  | Too_many_participants of { max : int }
  | Duplicate_participant of Customer_id.t
  | Owner_in_participants
  | Shares_mismatch of
      { total : Money.Amount.t
      ; sum : Money.Amount.t
      } (** the shares (the owner's included) do not add up to the total *)
  | Nothing_to_remind (** no share of the split is pending *)
  | Insufficient_funds of
      { available : Money.Amount.t
      ; required : Money.Amount.t
      }
[@@deriving sexp_of, compare, equal]

(** ["amount_not_positive"], ["reminder_too_soon"], ...: the constructor name in snake
    case, without arguments. *)
val code : t -> string

(** The refusal as an [Error.t], for callers that work in [Or_error]. *)
val to_error : t -> Error.t

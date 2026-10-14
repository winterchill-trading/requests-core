open! Core

type t =
  | Amount_not_positive
  | Currency_mismatch of
      { expected : Money.Currency.t
      ; got : Money.Currency.t
      }
  | Request_to_self
  | Not_a_party
  | Only_payer_pays
  | Only_payer_declines
  | Only_requester_cancels
  | Only_requester_reminds
  | Not_pending of Request_status.t
  | Reminder_too_soon of { retry_at : Payments_core.Utc_time.t }
  | Reminder_limit_reached of { max : int }
  | Own_link
  | Already_paid
  | Link_not_active of Link_status.t
  | Only_owner_revokes
  | Amount_required
  | Amount_fixed
  | Invalid_max_uses of { max : int }
  | Max_uses_on_single_use
  | No_participants
  | Too_many_participants of { max : int }
  | Duplicate_participant of Customer_id.t
  | Owner_in_participants
  | Shares_mismatch of
      { total : Money.Amount.t
      ; sum : Money.Amount.t
      }
  | Nothing_to_remind
  | Insufficient_funds of
      { available : Money.Amount.t
      ; required : Money.Amount.t
      }
[@@deriving sexp_of, compare, equal]

let code t =
  let name =
    match sexp_of_t t with
    | Atom name | List (Atom name :: _) -> name
    | List _ -> assert false
  in
  String.lowercase name
;;

let to_error t = Error.create_s [%sexp (t : t)]

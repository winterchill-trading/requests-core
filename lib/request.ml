open! Core
module Utc_time = Payments_core.Utc_time

module Stable = struct
  module V1 = struct
    module Payment = struct
      type t =
        { from : Ledger.Account_id.Stable.V1.t
        ; key : Ledger.Idempotency_key.Stable.V1.t
        ; transfer : Payments_core.Transfer.Id.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end

    type t =
      { id : Request_id.Stable.V1.t
      ; requester : Party.Stable.V1.t
      ; account : Ledger.Account_id.Stable.V1.t
      ; payer : Party.Stable.V1.t
      ; amount : Money.Amount.Stable.V1.t
      ; note : Note.Stable.V1.t option
      ; split : Split_id.Stable.V1.t option
      ; status : Request_status.Stable.V1.t
      ; created_at : Utc_time.Stable.V1.t
      ; expires_at : Utc_time.Stable.V1.t
      ; reminders : int
      ; last_reminded_at : Utc_time.Stable.V1.t option
      ; decided_at : Utc_time.Stable.V1.t option
      ; payment : Payment.t option
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let notice ~recipient ~at event : Notice.t = { recipient; at; event }

let create
  ?(policy = Policy.default)
  ~id
  ~(requester : Party.t)
  ~account
  ~(payer : Party.t)
  ~amount
  ?note
  ?split
  ~now
  ()
  =
  if not (Money.Amount.is_positive amount)
  then Error Refusal.Amount_not_positive
  else if Customer_id.equal requester.customer payer.customer
  then Error Refusal.Request_to_self
  else (
    let t =
      { id
      ; requester
      ; account
      ; payer
      ; amount
      ; note
      ; split
      ; status = Pending
      ; created_at = now
      ; expires_at = Time_ns.add now policy.request_lifetime
      ; reminders = 0
      ; last_reminded_at = None
      ; decided_at = None
      ; payment = None
      }
    in
    Ok
      ( t
      , [ notice
            ~recipient:payer.customer
            ~at:now
            (Request_received { request = id; from = requester; amount; note })
        ] ))
;;

let is_due t ~now = Time_ns.( >= ) now t.expires_at

let status t ~now : Request_status.t =
  match t.status with
  | Pending when is_due t ~now -> Expired
  | s -> s
;;

module Role = struct
  type t =
    | Requester
    | Payer
  [@@deriving sexp_of, compare, equal]
end

let role t customer : Role.t option =
  if Customer_id.equal customer t.requester.customer
  then Some Requester
  else if Customer_id.equal customer t.payer.customer
  then Some Payer
  else None
;;

module Command = struct
  type t =
    | Pay of
        { by : Customer_id.t
        ; from : Ledger.Account_id.t
        ; from_currency : Money.Currency.t
        }
    | Decline of { by : Customer_id.t }
    | Cancel of { by : Customer_id.t }
    | Remind of { by : Customer_id.t }
  [@@deriving sexp_of, compare, equal]
end

module Step = struct
  type nonrec t =
    { request : t
    ; notices : Notice.t list
    ; settlement : Settlement.Instruction.t option
    }
  [@@deriving sexp_of]
end

let reminder_window ~(policy : Policy.t) t =
  let last = Option.value t.last_reminded_at ~default:t.created_at in
  Time_ns.add last policy.reminder_gap
;;

let reminder_limit_reached ~(policy : Policy.t) t =
  match policy.max_reminders with
  | Some max when t.reminders >= max -> Some max
  | _ -> None
;;

(* Written out: [Result.( >>= )] takes its continuation as a local closure under OxCaml
   and does not fit a binding operator. *)
let ( let* ) r f =
  match r with
  | Ok x -> f x
  | Error _ as e -> e
;;

let expect_role t by (expected : Role.t) ~refusal =
  match role t by with
  | None -> Error Refusal.Not_a_party
  | Some r when Role.equal r expected -> Ok ()
  | Some _ -> Error refusal
;;

let expect_pending t ~now =
  match status t ~now with
  | Pending -> Ok ()
  | s -> Error (Refusal.Not_pending s)
;;

let decide t ~status ~now = { t with status; decided_at = Some now }

let apply ?(policy = Policy.default) t (command : Command.t) ~now =
  let open Result.Let_syntax in
  match command with
  | Pay { by; from; from_currency } ->
    let* () = expect_role t by Payer ~refusal:Only_payer_pays in
    let* () = expect_pending t ~now in
    let expected = Money.Amount.currency t.amount in
    let* () =
      if Money.Currency.equal expected from_currency
      then Ok ()
      else Error (Refusal.Currency_mismatch { expected; got = from_currency })
    in
    let%map instruction =
      Settlement.Instruction.for_request
        t.id
        ~payer:t.payer
        ~from
        ~payee:t.requester
        ~to_:t.account
        ~amount:t.amount
        ~note:t.note
      (* The amount is positive by construction, so the only failure left is paying from
         the account the money goes to. *)
      |> Result.map_error ~f:(fun _ -> Refusal.Same_account)
    in
    let request =
      { (decide t ~status:Paid ~now) with
        payment =
          Some
            { from; key = instruction.key; transfer = Settlement.outgoing_id instruction }
      }
    in
    { Step.request
    ; notices =
        [ notice
            ~recipient:t.requester.customer
            ~at:now
            (Request_paid { request = t.id; by = t.payer; amount = t.amount })
        ]
    ; settlement = Some instruction
    }
  | Decline { by } ->
    let* () = expect_role t by Payer ~refusal:Only_payer_declines in
    let%map () = expect_pending t ~now in
    { Step.request = decide t ~status:Declined ~now
    ; notices =
        [ notice
            ~recipient:t.requester.customer
            ~at:now
            (Request_declined { request = t.id; by = t.payer; amount = t.amount })
        ]
    ; settlement = None
    }
  | Cancel { by } ->
    let* () = expect_role t by Requester ~refusal:Only_requester_cancels in
    let%map () = expect_pending t ~now in
    { Step.request = decide t ~status:Cancelled ~now
    ; notices =
        [ notice
            ~recipient:t.payer.customer
            ~at:now
            (Request_cancelled { request = t.id; by = t.requester; amount = t.amount })
        ]
    ; settlement = None
    }
  | Remind { by } ->
    let* () = expect_role t by Requester ~refusal:Only_requester_reminds in
    let* () = expect_pending t ~now in
    let* () =
      match reminder_limit_reached ~policy t with
      | Some max -> Error (Refusal.Reminder_limit_reached { max })
      | None -> Ok ()
    in
    let retry_at = reminder_window ~policy t in
    let%map () =
      if Time_ns.( < ) now retry_at
      then Error (Refusal.Reminder_too_soon { retry_at })
      else Ok ()
    in
    let number = t.reminders + 1 in
    { Step.request = { t with reminders = number; last_reminded_at = Some now }
    ; notices =
        [ notice
            ~recipient:t.payer.customer
            ~at:now
            (Request_reminder
               { request = t.id
               ; from = t.requester
               ; amount = t.amount
               ; note = t.note
               ; number
               })
        ]
    ; settlement = None
    }
;;

let expire t ~now =
  match t.status with
  | Pending when is_due t ~now ->
    Some
      { Step.request = decide t ~status:Expired ~now:t.expires_at
      ; notices =
          [ notice
              ~recipient:t.requester.customer
              ~at:t.expires_at
              (Request_expired { request = t.id; payer = t.payer; amount = t.amount })
          ]
      ; settlement = None
      }
  | _ -> None
;;

let next_reminder_at ?(policy = Policy.default) t ~now =
  match status t ~now, reminder_limit_reached ~policy t with
  | Pending, None -> Some (reminder_window ~policy t)
  | _ -> None
;;

module Actions = struct
  type t =
    { can_pay : bool
    ; can_decline : bool
    ; can_cancel : bool
    ; can_remind : bool
    }
  [@@deriving sexp_of, compare, equal]
end

let actions ?(policy = Policy.default) t ~viewer ~now : Actions.t =
  let pending = Request_status.equal (status t ~now) Pending in
  let is role' = Option.equal Role.equal (role t viewer) (Some role') in
  let payer = pending && is Payer in
  let requester = pending && is Requester in
  { can_pay = payer
  ; can_decline = payer
  ; can_cancel = requester
  ; can_remind =
      requester
      && Option.exists (next_reminder_at ~policy t ~now) ~f:(fun at ->
        Time_ns.( <= ) at now)
  }
;;

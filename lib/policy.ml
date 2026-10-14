open! Core

type t =
  { request_lifetime : Time_ns.Span.t
  ; reminder_gap : Time_ns.Span.t
  ; max_reminders : int option
  ; max_link_uses : int
  ; max_split_participants : int
  }
[@@deriving sexp_of, compare, equal]

let default =
  { request_lifetime = Time_ns.Span.of_day 14.
  ; reminder_gap = Time_ns.Span.of_min 10.
  ; max_reminders = None
  ; max_link_uses = 100
  ; max_split_participants = 20
  }
;;

let check t =
  let positive_span name span =
    if Time_ns.Span.( > ) span Time_ns.Span.zero
    then Ok ()
    else Or_error.error_s [%message "span must be positive" name (span : Time_ns.Span.t)]
  in
  let positive name n =
    if n > 0
    then Ok ()
    else Or_error.error_s [%message "limit must be positive" name (n : int)]
  in
  Or_error.combine_errors_unit
    [ positive_span "request_lifetime" t.request_lifetime
    ; (* A zero gap is allowed: it only means reminders are not throttled. *)
      (if Time_ns.Span.( >= ) t.reminder_gap Time_ns.Span.zero
       then Ok ()
       else Or_error.error_string "reminder_gap must not be negative")
    ; (match t.max_reminders with
       | None -> Ok ()
       | Some n -> positive "max_reminders" n)
    ; positive "max_link_uses" t.max_link_uses
    ; positive "max_split_participants" t.max_split_participants
    ]
;;

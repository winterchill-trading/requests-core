open! Core
module Utc_time = Payments_core.Utc_time

module Stable = struct
  module V1 = struct
    module Event = struct
      type t =
        | Request_received of
            { request : Request_id.Stable.V1.t
            ; from : Party.Stable.V1.t
            ; amount : Money.Amount.Stable.V1.t
            ; note : Note.Stable.V1.t option
            }
        | Request_reminder of
            { request : Request_id.Stable.V1.t
            ; from : Party.Stable.V1.t
            ; amount : Money.Amount.Stable.V1.t
            ; note : Note.Stable.V1.t option
            ; number : int
            }
        | Request_paid of
            { request : Request_id.Stable.V1.t
            ; by : Party.Stable.V1.t
            ; amount : Money.Amount.Stable.V1.t
            }
        | Request_declined of
            { request : Request_id.Stable.V1.t
            ; by : Party.Stable.V1.t
            ; amount : Money.Amount.Stable.V1.t
            }
        | Request_cancelled of
            { request : Request_id.Stable.V1.t
            ; by : Party.Stable.V1.t
            ; amount : Money.Amount.Stable.V1.t
            }
        | Request_expired of
            { request : Request_id.Stable.V1.t
            ; payer : Party.Stable.V1.t
            ; amount : Money.Amount.Stable.V1.t
            }
        | Link_paid of
            { link : Link_id.Stable.V1.t
            ; by : Party.Stable.V1.t
            ; amount : Money.Amount.Stable.V1.t
            }
        | Link_completed of
            { link : Link_id.Stable.V1.t
            ; collected : Money.Amount.Stable.V1.t
            }
      [@@deriving bin_io, sexp, compare, equal]
    end

    type t =
      { recipient : Customer_id.Stable.V1.t
      ; at : Utc_time.Stable.V1.t
      ; event : Event.t
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

module Event = Stable.V1.Event

type t = Stable.V1.t =
  { recipient : Customer_id.t
  ; at : Utc_time.t
  ; event : Event.t
  }
[@@deriving sexp_of, compare, equal]

let key t =
  match t.event with
  | Request_received { request; _ } -> sprintf "request:%s:received" (Request_id.to_string request)
  | Request_reminder { request; number; _ } ->
    sprintf "request:%s:reminder:%d" (Request_id.to_string request) number
  | Request_paid { request; _ } -> sprintf "request:%s:paid" (Request_id.to_string request)
  | Request_declined { request; _ } -> sprintf "request:%s:declined" (Request_id.to_string request)
  | Request_cancelled { request; _ } ->
    sprintf "request:%s:cancelled" (Request_id.to_string request)
  | Request_expired { request; _ } -> sprintf "request:%s:expired" (Request_id.to_string request)
  | Link_paid { link; by; _ } ->
    sprintf "link:%s:paid:%s" (Link_id.to_string link) (Customer_id.to_string by.customer)
  | Link_completed { link; _ } -> sprintf "link:%s:completed" (Link_id.to_string link)
;;

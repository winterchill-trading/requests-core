open! Core
module Utc_time = Payments_core.Utc_time

module Stable = struct
  module V1 = struct
    module Share = struct
      type t =
        { request : Request_id.Stable.V1.t
        ; payer : Party.Stable.V1.t
        ; amount : Money.Amount.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end

    type t =
      { id : Split_id.Stable.V1.t
      ; owner : Party.Stable.V1.t
      ; account : Ledger.Account_id.Stable.V1.t
      ; title : Note.Stable.V1.t
      ; total : Money.Amount.Stable.V1.t
      ; own_share : Money.Amount.Stable.V1.t
      ; source : string option
      ; shares : Share.t list
      ; created_at : Utc_time.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

module Equal_shares = struct
  type t =
    { own_share : Money.Amount.t
    ; other_share : Money.Amount.t
    ; remainder : Money.Amount.t
    }
  [@@deriving sexp_of, compare, equal]
end

let check_participants ~(policy : Policy.t) n : (unit, Refusal.t) Result.t =
  if n < 1
  then Error No_participants
  else if n > policy.max_split_participants
  then Error (Too_many_participants { max = policy.max_split_participants })
  else Ok ()
;;

let equal_shares ?(policy = Policy.default) ~total ~others () =
  let open Result.Let_syntax in
  let%bind () =
    if Money.Amount.is_positive total then Ok () else Error Refusal.Amount_not_positive
  in
  let%map () = check_participants ~policy others in
  let currency = Money.Amount.currency total in
  let minor = Money.Amount.minor_units total in
  let people = Z.of_int (others + 1) in
  (* Z.div truncates toward zero, which is the floor for a positive total. *)
  let each = Z.div minor people in
  let remainder = Z.sub minor (Z.mul each people) in
  let amount = Money.Amount.of_minor_units currency in
  { Equal_shares.own_share = amount (Z.add each remainder)
  ; other_share = amount each
  ; remainder = amount remainder
  }
;;

module Created = struct
  type nonrec t =
    { split : t
    ; requests : Request.t list
    ; notices : Notice.t list
    }
  [@@deriving sexp_of]
end

let validate_shares ~policy ~(owner : Party.t) ~total ~own_share (shares : Share.t list) =
  let open Result.Let_syntax in
  let currency = Money.Amount.currency total in
  let in_currency a : (unit, Refusal.t) Result.t =
    if Money.Currency.equal (Money.Amount.currency a) currency
    then Ok ()
    else Error (Currency_mismatch { expected = currency; got = Money.Amount.currency a })
  in
  let%bind () =
    if Money.Amount.is_positive total then Ok () else Error Refusal.Amount_not_positive
  in
  let%bind () = check_participants ~policy (List.length shares) in
  let%bind () = in_currency own_share in
  let%bind () =
    if Money.Amount.is_negative own_share
    then Error Refusal.Amount_not_positive
    else Ok ()
  in
  let%bind () =
    if List.exists shares ~f:(fun s -> Customer_id.equal s.payer.customer owner.customer)
    then Error Refusal.Owner_in_participants
    else Ok ()
  in
  let%bind () =
    match
      List.find_a_dup shares ~compare:(fun (a : Share.t) b ->
        Customer_id.compare a.payer.customer b.payer.customer)
    with
    | Some dup -> Error (Refusal.Duplicate_participant dup.payer.customer)
    | None -> Ok ()
  in
  let%bind () =
    List.fold_result shares ~init:() ~f:(fun () s ->
      let%bind () = in_currency s.amount in
      if Money.Amount.is_positive s.amount
      then Ok ()
      else Error Refusal.Amount_not_positive)
  in
  let sum =
    List.fold shares ~init:own_share ~f:(fun acc s -> Money.Amount.add_exn acc s.amount)
  in
  if Money.Amount.equal sum total then Ok () else Error (Shares_mismatch { total; sum })
;;

let create
  ?(policy = Policy.default)
  ~id
  ~owner
  ~account
  ~title
  ~total
  ~own_share
  ?source
  ~shares
  ~now
  ()
  =
  let open Result.Let_syntax in
  let%bind () = validate_shares ~policy ~owner ~total ~own_share shares in
  let%map created =
    List.map shares ~f:(fun (s : Share.t) ->
      Request.create
        ~policy
        ~id:s.request
        ~requester:owner
        ~account
        ~payer:s.payer
        ~amount:s.amount
        ~note:title
        ~split:id
        ~now
        ())
    |> Result.all
  in
  { Created.split =
      { id; owner; account; title; total; own_share; source; shares; created_at = now }
  ; requests = List.map created ~f:fst
  ; notices = List.concat_map created ~f:snd
  }
;;

module Status = struct
  type t =
    | Open
    | Settled
    | Closed
  [@@deriving sexp, compare, equal, enumerate]

  let of_shares statuses =
    if List.mem statuses Request_status.Pending ~equal:Request_status.equal
    then Open
    else if List.for_all statuses ~f:(Request_status.equal Paid)
    then Settled
    else Closed
  ;;
end

module Summary = struct
  type t =
    { status : Status.t
    ; participants : int
    ; paid : int
    ; collected : Money.Amount.t
    ; outstanding : Money.Amount.t
    }
  [@@deriving sexp_of, compare, equal]
end

let share_requests t ~requests =
  List.map t.shares ~f:(fun (s : Share.t) ->
    match
      List.find requests ~f:(fun (r : Request.t) -> Request_id.equal r.id s.request)
    with
    | Some r -> Ok (s, r)
    | None ->
      Or_error.error_s
        [%message "split share has no request" ~request:(s.request : Request_id.t)])
  |> Or_error.all
;;

let summary t ~requests ~now =
  let open Or_error.Let_syntax in
  let%map pairs = share_requests t ~requests in
  let with_status = List.map pairs ~f:(fun (s, r) -> s, Request.status r ~now) in
  let sum status =
    List.fold
      with_status
      ~init:(Money.Amount.zero (Money.Amount.currency t.total))
      ~f:(fun acc ((s : Share.t), st) ->
        if Request_status.equal st status then Money.Amount.add_exn acc s.amount else acc)
  in
  { Summary.status = Status.of_shares (List.map with_status ~f:snd)
  ; participants = List.length t.shares
  ; paid = List.count with_status ~f:(fun (_, st) -> Request_status.equal st Paid)
  ; collected = sum Paid
  ; outstanding = sum Pending
  }
;;

let remind ?(policy = Policy.default) t ~by ~requests ~now =
  if not (Customer_id.equal by t.owner.customer)
  then Error Refusal.Only_requester_reminds
  else (
    let pending =
      List.filter requests ~f:(fun (r : Request.t) ->
        Option.exists r.split ~f:(Split_id.equal t.id)
        && Request_status.equal (Request.status r ~now) Pending)
    in
    if List.is_empty pending
    then Error Refusal.Nothing_to_remind
    else (
      let results =
        List.map pending ~f:(fun r -> Request.apply ~policy r (Remind { by }) ~now)
      in
      match List.filter_map results ~f:Result.ok with
      | _ :: _ as steps -> Ok steps
      | [] ->
        (* Nothing could be reminded: answer with the refusal that clears first. *)
        let refusals =
          List.filter_map results ~f:(function
            | Ok _ -> None
            | Error r -> Some r)
        in
        let retry_at : Refusal.t -> Time_ns.t option = function
          | Reminder_too_soon { retry_at } -> Some retry_at
          | _ -> None
        in
        (match
           List.min_elt (List.filter_map refusals ~f:retry_at) ~compare:Time_ns.compare
         with
         | Some retry_at -> Error (Reminder_too_soon { retry_at })
         | None -> Error (List.hd_exn refusals))))
;;

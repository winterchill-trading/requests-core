open! Core

module Make (M : Monad.S) = struct
  type 'a io = 'a M.t

  type t =
    { requests : Request.t Request_id.Table.t
    ; links : Link.t Link_id.Table.t
    ; tokens : (Link_token.t, Link_id.t) Hashtbl.t
    ; splits : Split.t Split_id.Table.t
    ; notices : (string, Notice.t) Hashtbl.t
    }

  let create () =
    { requests = Request_id.Table.create ()
    ; links = Link_id.Table.create ()
    ; tokens = Hashtbl.create (module Link_token)
    ; splits = Split_id.Table.create ()
    ; notices = Hashtbl.create (module String)
    }
  ;;

  let return = M.return
  let take limit l = List.take l (Int.max 0 limit)

  (* Newest first by creation time, ties broken by id so the order is total. *)
  let newest_first ~created ~id ~compare_id a b =
    match Time_ns.compare (created b) (created a) with
    | 0 -> compare_id (id a) (id b)
    | c -> c
  ;;

  let insert_request t (r : Request.t) =
    match Hashtbl.find t.requests r.id with
    | Some existing -> return (`Exists existing)
    | None ->
      Hashtbl.set t.requests ~key:r.id ~data:r;
      return `Inserted
  ;;

  let update_request t ~(expected : Request.t) (next : Request.t) =
    match Hashtbl.find t.requests expected.id with
    | Some current when Request.equal current expected && Request_id.equal next.id expected.id
      ->
      Hashtbl.set t.requests ~key:next.id ~data:next;
      return `Updated
    | current -> return (`Stale current)
  ;;

  let find_request t id = return (Hashtbl.find t.requests id)

  let requests_of t customer ~(side : Request.Role.t) ~limit =
    Hashtbl.data t.requests
    |> List.filter ~f:(fun (r : Request.t) ->
      Option.equal Request.Role.equal (Request.role r customer) (Some side))
    |> List.sort
         ~compare:
           (newest_first
              ~created:(fun (r : Request.t) -> r.created_at)
              ~id:(fun (r : Request.t) -> r.id)
              ~compare_id:Request_id.compare)
    |> take limit
    |> return
  ;;

  let requests_of_split t split =
    Hashtbl.data t.requests
    |> List.filter ~f:(fun (r : Request.t) -> Option.exists r.split ~f:(Split_id.equal split))
    |> return
  ;;

  let due_requests t ~now ~limit =
    Hashtbl.data t.requests
    |> List.filter ~f:(fun (r : Request.t) ->
      Request_status.equal r.status Pending && Time_ns.( <= ) r.expires_at now)
    |> List.sort ~compare:(fun (a : Request.t) b ->
      match Time_ns.compare a.expires_at b.expires_at with
      | 0 -> Request_id.compare a.id b.id
      | c -> c)
    |> take limit
    |> return
  ;;

  let insert_link t (l : Link.t) =
    match Hashtbl.find t.links l.id with
    | Some existing -> return (`Exists existing)
    | None ->
      if Hashtbl.mem t.tokens l.token
      then return `Token_taken
      else (
        Hashtbl.set t.links ~key:l.id ~data:l;
        Hashtbl.set t.tokens ~key:l.token ~data:l.id;
        return `Inserted)
  ;;

  let update_link t ~(expected : Link.t) (next : Link.t) =
    match Hashtbl.find t.links expected.id with
    | Some current
      when Link.equal current expected
           && Link_id.equal next.id expected.id
           && Link_token.equal next.token expected.token ->
      Hashtbl.set t.links ~key:next.id ~data:next;
      return `Updated
    | current -> return (`Stale current)
  ;;

  let find_link t id = return (Hashtbl.find t.links id)

  let find_link_by_token t token =
    return (Option.bind (Hashtbl.find t.tokens token) ~f:(Hashtbl.find t.links))
  ;;

  let links_of t customer =
    Hashtbl.data t.links
    |> List.filter ~f:(fun (l : Link.t) -> Customer_id.equal l.owner.customer customer)
    |> List.sort
         ~compare:
           (newest_first
              ~created:(fun (l : Link.t) -> l.created_at)
              ~id:(fun (l : Link.t) -> l.id)
              ~compare_id:Link_id.compare)
    |> return
  ;;

  let insert_split t (s : Split.t) ~requests =
    match Hashtbl.find t.splits s.id with
    | Some existing -> return (`Exists existing)
    | None ->
      (match
         List.find requests ~f:(fun (r : Request.t) -> Hashtbl.mem t.requests r.id)
       with
       | Some r -> return (`Request_exists r.id)
       | None ->
         Hashtbl.set t.splits ~key:s.id ~data:s;
         List.iter requests ~f:(fun (r : Request.t) ->
           Hashtbl.set t.requests ~key:r.id ~data:r);
         return `Inserted)
  ;;

  let find_split t id = return (Hashtbl.find t.splits id)

  let splits_of t customer ?source () =
    Hashtbl.data t.splits
    |> List.filter ~f:(fun (s : Split.t) ->
      Customer_id.equal s.owner.customer customer
      && Option.for_all source ~f:(fun src -> Option.equal String.equal s.source (Some src)))
    |> List.sort
         ~compare:
           (newest_first
              ~created:(fun (s : Split.t) -> s.created_at)
              ~id:(fun (s : Split.t) -> s.id)
              ~compare_id:Split_id.compare)
    |> return
  ;;

  let add_notices t notices =
    List.iter notices ~f:(fun n ->
      ignore (Hashtbl.add t.notices ~key:(Notice.key n) ~data:n : [ `Ok | `Duplicate ]));
    return ()
  ;;

  let notices_for t customer ~since ~limit =
    Hashtbl.data t.notices
    |> List.filter ~f:(fun (n : Notice.t) ->
      Customer_id.equal n.recipient customer && Time_ns.( >= ) n.at since)
    |> List.sort ~compare:(fun (a : Notice.t) b ->
      match Time_ns.compare b.at a.at with
      | 0 -> String.compare (Notice.key a) (Notice.key b)
      | c -> c)
    |> take limit
    |> return
  ;;
end

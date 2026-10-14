(* The README's quick start, built in CI so it stays correct. *)

open! Core
open Requests_core

let eur s = Money.Amount.of_decimal_string Money.Currency.eur s |> Or_error.ok_exn
let ada = Party.create_exn ~customer:(Customer_id.of_string "ada") ~name:"Ada"
let ben = Party.create_exn ~customer:(Customer_id.of_string "ben") ~name:"Ben"
let account id = Ledger.Account_id.of_string ("customer:" ^ id)

let () =
  let now = Time_ns.now () in
  match
    Request.create
      ~id:(Request_id.of_string "req-1")
      ~requester:ada
      ~account:(account "ada")
      ~payer:ben
      ~amount:(eur "12.50")
      ~now
      ()
  with
  | Error refusal -> print_endline (Refusal.code refusal)
  | Ok (request, _notices) ->
    (match
       Request.apply
         request
         (Pay
            { by = ben.customer
            ; from = account "ben"
            ; from_currency = Money.Currency.eur
            })
         ~now
     with
     | Error refusal -> print_endline (Refusal.code refusal)
     | Ok step ->
       (* Store step.request, book step.settlement with Settlement.book and store
          step.notices in one transaction, or drop all three. *)
       print_s [%sexp (step.settlement : Settlement.Instruction.t option)])
;;

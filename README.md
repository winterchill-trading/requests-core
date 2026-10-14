# requests-core

Money requests, payment links and bill splits between customers of the same
institution, as pure state machines over [`money`](../money), [`ledger`](../ledger) and
[`payments-core`](../payments-core).

- **Money requests.** One customer asks another for an amount into one of their
  accounts. A request is pending until the payer pays or declines it, the requester
  cancels it, or its lifetime (14 days by default) runs out; it reads as expired the
  moment that happens, before any sweep has stored it.
- **Reminders with limits.** The requester may remind the payer at most once per gap
  (10 minutes by default, counted from creation for the first one) and, optionally, a
  limited number of times.
- **Payment links.** A link is reached through a token of 32 random bytes from the
  operating system's generator, written as 43 base64url characters; it is never derived
  from an id or a counter. Anyone holding the token sees only the owner's display name,
  the amount (or that the payer chooses it), the currency and the note, and once the link
  cannot be paid, only why. Links are single-use or multi-use with an optional cap, live
  1, 7 or 30 days, can be revoked, refuse their owner and accept one payment per payer.
  A link that cannot be paid says why (revoked, expired, completed) before anything
  about the payer, such as having paid already.
- **Bill splits.** A split records who owes what for a shared expense and creates one
  request per participant. Shares must add up to the total; an equal split gives each
  participant the total divided by the number of people, rounded down to the minor unit,
  and leaves the remainder with the requester. The split's status (open, settled,
  closed) is derived from its requests.
- **Settlement through payments-core.** Paying a request or a link returns a settlement
  instruction. Booking it creates an intraledger outgoing transfer from the payer (hold,
  then capture into the intraledger settlement account) and an incoming transfer to the
  payee, with ledger idempotency keys derived from `request:<id>` or
  `link:<id>:<payer>`, so a retried booking produces the same entries and the journal
  books them once.
- **Notices as values.** Every transition returns the notices to deliver (request
  received, reminded, paid, declined, cancelled, expired; link paid, completed), each
  with a stable key. The library sends nothing.
- **Refusals as values.** Every refusal is a constructor of `Refusal.t` with a stable
  snake-case code that a service maps to its own errors.

## Why separate

Asking for money is common to every retail bank and wallet, and the rules that make it
safe are easy to get subtly wrong: who may act on a request, when it expires, how often
the payer can be nagged, how a link token resists guessing, how a split's remainder is
assigned, and how a payment is booked exactly once. Keeping them in a small library of
pure functions lets each rule be tested once, with properties, and lets any service wrap
them in its own transport and storage. Payment rails, cards and balances stay in
`payments-core` and `ledger`; this library only decides and describes.

## Quick start

```ocaml
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
         (Pay { by = ben.customer; from = account "ben"; from_currency = Money.Currency.eur })
         ~now
     with
     | Error refusal -> print_endline (Refusal.code refusal)
     | Ok step ->
       (* Store step.request, book step.settlement with Settlement.book and store
          step.notices in one transaction, or drop all three. *)
       print_s [%sexp (step.settlement : Settlement.Instruction.t option)])
;;
```

[`examples/quickstart.ml`](examples/quickstart.ml) runs a request, a link and a split end
to end against ledger balances and the in-memory store; CI checks its output.

## Modules

| Module | What it is |
| --- | --- |
| `Customer_id`, `Request_id`, `Link_id`, `Split_id` | Checked ids (1 to 48 characters of `[A-Za-z0-9_.-]`) |
| `Note` | Normalised short text (35 characters), for notes and titles |
| `Party` | A customer id with a display name |
| `Policy` | Lifetimes and limits: request lifetime, reminder gap and count, link cap bound, split size |
| `Request_status`, `Request` | The request state machine: `create`, `apply` (pay, decline, cancel, remind), `expire`, `status`, `actions` |
| `Link_token`, `Link_status`, `Link` | Payment links: `create`, `pay`, `revoke`, `status`, `status_refusal`, `check`, `public_view` |
| `Split` | `equal_shares`, `create` (with its requests), `summary`, `remind` |
| `Settlement` | The instruction a payment produces and its booking as intraledger transfers |
| `Notice` | Notices for customers, with stable keys |
| `Refusal` | Every refusal, with stable codes |
| `Store`, `Store_memory`, `Store_conformance` | Persistence as a module type, an in-memory implementation and the scenarios every implementation must pass |

## Lifecycles

```
request: pending --pay (payer)------> paid
         pending --decline (payer)--> declined
         pending --cancel (requester)-> cancelled
         pending --lifetime passes--> expired     (read at once; `expire` stores it)

link:    active --last allowed payment--> completed
         active --revoke (owner)--------> revoked
         active --expiry passes---------> expired (read, never stored)

split:   open (a share is pending) | settled (all paid) | closed (none pending, not all paid)
```

A service can tell a visitor why a link cannot be paid before asking for an account or an
amount. `Link.status_refusal l ~now` answers `Revoked`, `Expired`, `Completed` (a paid
single-use link) or `Cap_reached { max_uses }`, each with a stable code
(`link_cap_reached`, ...), and `None` while the link is active. `Link.check ~payer l ~now`
adds the payer checks of `pay` (own link, already paid) in the same order, so `Ok ()`
leaves only account and amount refusals.

## Storage

The library never persists anything. A service implements `Store.S` over its own
database. Inserts are atomic on their keys (a link on both its id and its token), and
updates are compare-and-set: two workers acting on the same request or link cannot both
succeed, so a link's cap and its one-payment-per-payer rule hold under races. A split is
inserted together with its share requests, all or nothing. Notices are stored once per
key. Run `Store_conformance.Make` against the implementation in the service's test
suite; `Store_memory` passes the same scenarios. Persisted types have `Stable.V1`
bin_prot and sexp forms with pinned digests, and decoding checks ids, notes and tokens
again.

## Settlement

`Settlement.book` takes ledger balances, an instruction and how the payer authorised the
payment (`Payments_core.Sca.Authorization.t`: a verified SCA challenge or an exemption)
and returns the two settled `Payments_core.Transfer.t` values and three entries (hold,
capture, deposit) to append together, for example with `Payments_core.Booking.post`.
Open `Settlement.accounts` once per currency. `Settlement.check_funds` answers an
overdraft with a typed refusal before the ledger is asked.

## Tests

Expect tests pin each lifecycle, the refusals and their order, the public view, the
bookings and their idempotency, the store scenarios and the stable digests. Quickcheck
properties check that random command sequences never leave a final request state, pay at
most once, emit exactly one notice to the other party per change and space reminders by
the gap; that random link payments never exceed the cap, never come from the owner or
twice from one payer, never arrive after expiry, and complete exactly at the cap; that
equal shares add up to the total with a remainder below one minor unit per person; and
that link tokens round-trip.

## Known gaps

- One currency per request and link; a payer whose account is in another currency is
  refused rather than converted.
- Requests to people who are not yet customers (by e-mail or phone, claimed on sign-up)
  are not modelled; the payer must be a customer.
- Amount limits per request are left to the service's own limits and risk rules.

## For agents

[`AGENTS.md`](AGENTS.md) has the build commands, conventions and pitfalls.

## Used by

No org repositories yet.

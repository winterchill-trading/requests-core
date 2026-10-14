(lang dune 3.17)

(name requests-core)

(generate_opam_files true)

(license MIT)

(authors "WinterChill AI")

(maintainers "hello@winterchill.xyz")

(source
 (github winterchill-trading/requests-core))

(homepage "https://github.com/winterchill-trading/requests-core")

(bug_reports "https://github.com/winterchill-trading/requests-core/issues")

(documentation "https://github.com/winterchill-trading/requests-core#readme")

(package
 (name requests-core)
 (synopsis
  "Money requests, payment links and bill splits between customers of one institution")
 (description
  "requests-core models the ways one customer asks another for money inside the same institution: money requests (pending, paid, declined, cancelled, expired), reminders with a minimum gap and an optional count limit, shareable payment links behind random unguessable tokens whose public view shows only the owner's name, the amount and the note, and bill splits with equal shares where the requester absorbs the remainder. Every lifecycle is a pure state machine that returns the new state, the notices to deliver and, when money moves, a settlement instruction booked as an intraledger payment through payments-core with a deterministic idempotency key. Persistence is a module type with an in-memory implementation and a conformance suite. Requires the OxCaml compiler.")
 (tags
  (payments requests payment-links bill-split banking oxcaml))
 (depends
  oxcaml
  (ocaml
   (and
    (>= 5.2.0)
    (< 5.3~)))
  dune
  (core
   (and
    (>= v0.18~preview.130.106+341)
    (< v0.19~)))
  (ppx_jane
   (and
    (>= v0.18~preview.130.106+341)
    (< v0.19~)))
  (zarith
   (>= 1.12))
  (cryptokit
   (>= 1.16))
  fixed-decimal
  money
  ledger
  payments-core
  (base_quickcheck :with-test)
  (odoc :with-doc)))

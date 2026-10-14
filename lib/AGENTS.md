# AGENTS.md (lib/)

Library `requests_core`: the request, link and split state machines, settlement
booking, notices, refusals and the store interface.

- `requests_core.ml` re-exports every module with a one-line doc; add new modules there.
- State machines (`Request`, `Link`, `Split`) are pure. Each operation takes `~now` and
  returns the next value plus notices and, for payments, a `Settlement.Instruction.t`.
  Keep checks in the order the `.mli` documents; tests pin it.
- `Settlement.book` goes through `Payments_core.Transfer` and `Payments_core.Booking`;
  do not post ledger entries by hand. Keys and transfer ids derive from the
  instruction key, so retries reproduce the same entries.
- `Link_token` is the only source of randomness. Keep tokens 32 random bytes; never
  derive them from ids.
- `Link.public_view` must expose only name, amount, currency and note (and nothing once
  unavailable); a test checks that ids and account names do not leak.
- `Store`, `Store_memory`, `Store_conformance`: a new store operation needs an in-memory
  implementation and a conformance scenario in the same change.
- Persisted types live in `Stable.V1` submodules; their digests are pinned in
  `test/test_stable.ml`.
- Build: `dune build --root .. @requests-core/all` from the repository root.

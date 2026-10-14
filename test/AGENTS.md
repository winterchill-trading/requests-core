# AGENTS.md (test/)

Inline tests for `requests_core`: one file per module, plus `test_properties.ml`
(Quickcheck over random command sequences), `test_stable.ml` (pinned digests and
round trips) and `test_store_conformance.ml`.

- Run: `dune build --root .. @requests-core/runtest`. Accept new expect output with
  `dune promote --root ..` (with the same `DUNE_BUILD_DIR`), read the diff first, then
  format.
- `helpers.ml` has the fixed clock (`t0`, `after_min`, `after_day`), the parties
  `alice`, `bob`, `carol`, EUR accounts and `ledger` (balances with funded accounts).
- A digest change in `test_stable.ml` means stored data stops decoding: add a new
  stable version instead of promoting it.
- Quickcheck runs inside `let%test_unit` with `Quickcheck.test`; keep generators
  deterministic (no wall clock).

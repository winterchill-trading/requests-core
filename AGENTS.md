# AGENTS.md

## Purpose

`requests-core` models money requests, payment links and bill splits between customers
of the same institution as pure state machines. Payments are booked as intraledger
transfers through `payments-core`; persistence is a `Store` module type with an
in-memory implementation and a conformance suite.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `requests_core` (see `lib/AGENTS.md`) |
| `test/` | Expect, Quickcheck and stable-digest tests (see `test/AGENTS.md`) |
| `examples/` | `quickstart.ml` (output checked by `runtest`) and the README snippet (see `examples/AGENTS.md`) |
| `.github/` | CI workflow (see `.github/AGENTS.md`) |
| `dune-project`, `requests-core.opam` | Package metadata; the `.opam` file is generated from `dune-project` |
| `CHANGES.md` | Changelog; user-visible changes go under "Unreleased" |

## Build, test, docs

Run from this directory. The workspace root `..` holds the sibling checkouts and the
shared `dune-workspace`.

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @requests-core/all
opam exec --switch 5.2.0+ox -- dune build --root .. @requests-core/runtest
opam exec --switch 5.2.0+ox -- dune build --root .. @requests-core/doc
DUNE_BUILD_DIR=../_build-requests-core opam exec --switch 5.2.0+ox -- dune build --root .. @requests-core/all
```

The last line is for parallel work: a private build directory avoids the lock shared
with other repositories in the workspace. A sibling being edited can break the build;
check which repository an error's file is in before acting on it.

Standalone (outside the workspace), pin the siblings from GitHub as the CI workflow
does, then build:

```sh
opam pin add -n -y fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git
# repeat for money, ledger, payments-core (see .github/workflows/ci.yml)
opam install . --deps-only --with-test
dune build && dune test
```

## Conventions

- Formatting: `dune build --root .. @requests-core/fmt --auto-promote`, after the tests
  pass and `dune promote` is done. Never `dune fmt` at the workspace root; it reformats
  every sibling repository.
- Every module has an `.mli` with odoc on every public value. Use `open! Core`,
  labelled arguments and `ppx_jane`.
- Transitions are pure: they take the value and `~now` and return the next value, the
  notices and, for payments, a `Settlement.Instruction.t`. No clocks, randomness (except
  `Link_token.generate`) or I/O in `lib/`.
- Refusals are `Refusal.t` constructors, never exceptions or strings. A new refusal
  needs a test that shows where it is checked in the order documented in the `.mli`.
- Persisted types are `Stable.V1` with a pinned `[%bin_digest]` in
  `test/test_stable.ml`. A changed digest is a version decision: add `V2`, keep `V1`
  readable.
- Times in records are `Payments_core.Utc_time.t` (UTC sexps on every machine; plain
  `Time_ns` prints the local zone).
- Idempotency keys are derived (`request:<id>`, `link:<id>:<payer>`), never random, so a
  retry books the same entries.
- Tests: `ppx_expect` with `-source-tree-root .`, and Quickcheck in `let%test_unit`
  with `Quickcheck.test`.
- Comment non-obvious choices for human readers; add a `CHANGES.md` "Unreleased" entry
  for user-visible changes.

## Dependencies and dependents

- Depends on: `money`, `ledger`, `payments-core` (and `fixed-decimal` through them),
  plus `core`, `zarith` and `cryptokit`. No database, HTTP or `async`.
- Used by: no org repositories yet.
- CI pin order: `fixed-decimal`, `money`, `ledger`, `payments-core`. A new sibling
  dependency needs its pin in the CI workflow in the same commit.

## CI

`.github/workflows/ci.yml` runs the `ox-setup` action with the pins above (its opam
switch is cached between runs), then `dune build`, `dune test` (which also checks the
quickstart output) and `dune build @doc`, failing on any odoc warning. The `obj-magic`
job calls the shared reusable workflow, which fails on `Obj.magic`. To check a run:
`gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`. Do not poll
in a loop.

## Pitfalls

- `Result.( >>= )` takes its continuation as a local closure under OxCaml, so
  `let ( let* ) = Result.( >>= )` does not type; `lib/request.ml` writes the operator
  out. `Result.Let_syntax` (`let%bind`, `let%map`) works.
- A record type declared `private` in an `.mli` cannot be built or updated with
  `{ r with ... }` outside its module, including in `Store_conformance` and tests; go
  through the constructors.
- odoc treats `{!status}` as ambiguous next to a `status` field; write `{!val-status}`.
- Cryptokit's `Random.system_rng` raises on Unix; `Link_token` reads `/dev/urandom`
  through `Random.device_rng`.
- `Booking.apply` refuses idempotency keys it has already booked: a second booking of
  the same instruction is an error at the balances, a `Duplicate` at the journal.
- After a test that raised, `dune promote` writes an `[@@expect.uncaught_exn]` block
  with a backtrace; delete it once the test is fixed.

## Where to read more

- `README.md` (lifecycles, storage, settlement, known gaps), `CHANGES.md`.
- `../specs/repos/requests-core.md` for status and design decisions, once written.
- Skills in `../oxcaml-claude-skills/skills/`: `banking-standards`,
  `janestreet-ocaml-style`.
- `../oxcaml-claude-skills/AGENTS.md`: the workspace-wide guide.
- `../oxcaml-claude-skills/GOTCHAS.md`: the dated log these pitfalls come from.

## Never do

- Run `opam install`, `opam upgrade` or `opam pin` on the shared `5.2.0+ox` switch
  without a dry run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`. Abort if the
  plan touches `ocaml-variants`, `core`, `base`, `async` or `ppx_jane`.
- Publish, tag or release a version from this repository without the maintainers asking.
- Commit credentials or print secrets. Configuration comes from the environment.
- Poll CI in a loop.

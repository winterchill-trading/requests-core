# AGENTS.md (.github/)

`workflows/ci.yml` builds and tests this repository on Ubuntu with the `ox-setup`
action, then builds the odoc docs and fails on any warning. Its `pins:` block lists the
sibling repositories in dependency order (`fixed-decimal`, `money`, `ledger`,
`payments-core`); keep it in sync with `dune-project` in the same commit as a new
dependency. The `obj-magic` job calls the shared reusable workflow from the `infra`
repository.

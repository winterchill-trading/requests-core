# AGENTS.md (examples/)

Executables built with the library, not installed.

- `quickstart.ml`: a request, a link and a split end to end against ledger balances and
  `Store_memory`. Its output is diffed against `quickstart.expected` by `runtest`; after
  an intended change, run it and replace the expected file:
  `dune exec --root .. ./requests-core/examples/quickstart.exe > examples/quickstart.expected`.
  It prints only the token's length, since tokens are random.
- `readme.ml`: the README quick start, compiled so the README stays correct. Edit both
  together.

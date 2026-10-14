# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

### Changed

- `Link.pay` checks the link's status before "already paid": a revoked, expired or
  completed link answers `Link_not_active` to every payer, including one who paid it.

### Added

- `Customer_id`, `Request_id`, `Link_id`, `Split_id`: checked ids with stable forms.
- `Note`: normalised short text for notes and titles.
- `Party`, `Policy`: display names; request lifetime, reminder gap and count limit, link
  cap bound and split size.
- `Request`: money request state machine (pay, decline, cancel, remind, expire), roles
  and the actions a viewer may take.
- `Link_token`, `Link`: payment links behind random base64url tokens, single or
  multi-use, fixed or open amounts, 1/7/30-day lifetimes, revocation and a public view
  limited to name, amount and note.
- `Split`: bill splits with equal shares (remainder to the requester), derived status,
  summaries and reminders.
- `Settlement`: payments booked as intraledger transfers through payments-core with
  idempotency keys derived from the request or link and the payer.
- `Notice`, `Refusal`: notices and refusals as values with stable keys and codes.
- `Store`, `Store_memory`, `Store_conformance`: persistence as a module type, an
  in-memory store and its conformance scenarios.

# chimera-companion development

<!-- BEGIN GENERATED CONTRACT 9ae22483c7427c0505db10514e9fdfa967d38a56e3d35be76b57d18d013ae12e -->
# Development contract

Status: current. Owner: maintainers of the affected repositories.

This contract applies to people and coding agents. Repository AGENTS.md files contain a generated copy so a standalone checkout retains these obligations. CLAUDE.md points to AGENTS.md. Change this source and run `npm run quality:sync` from the ERP repository; do not edit generated sections.

## Before changing code

- Read AGENTS.md and the canonical documentation relevant to the change. Inspect the branch and working tree; preserve concurrent work.
- Identify the owning service, affected business rules, APIs, SQL, authorization, compatibility and tests. Find an existing component or service before creating another.
- Resolve disagreements between intended rules and current behavior explicitly. Neither an old document nor current code silently overrides a product decision.
- Keep one active checklist for a cross-repository task. Small changes do not need a separate plan document.

## Implementation

- Keep business logic in its owning service. UI, verification blocks and hardware adapters must call the existing behavior rather than copy calculations.
- PostgreSQL business access belongs to domain SQL functions, declared in versioned SQL files. TypeScript authenticates, validates transport contracts, calls typed routines and performs external I/O; it must not build table queries or duplicate persistent business calculations. Reuse existing routines and triggers. Preserve atomicity, tenant scope, revisions, idempotency and audit steps. Runtime SQL exceptions are explicit infrastructure or read-only external-source adapters, never a generic SQL escape hatch. Run the SQL-boundary check; existing migration debt may decrease but new inline SQL must not be added.
- Reuse shadcn controls and existing layout primitives. Do not nest decorative cards in cards, dialogs, sheets or drawers, including equivalent div wrappers.
- Enforce organization, location, actor and permissions on the server. Preserve transactions, idempotency, historical records and compatibility for stock, money and documents.
- Deliver schema changes through reproducible migrations owned by the correct repository. Do not repair only the local database.
- Update the canonical document when behavior changes. Index new documents; use an ADR only for a durable decision. Do not create per-turn FINAL, COMPLETE, SUMMARY or PROGRESS documents.
- Add meaningful coverage for new behavior and a regression case for a bug. Do not mirror implementation details or add tests for a wording-only edit.
- Do not weaken assertions, remove security checks or change expected behavior merely to make a test pass. Explain necessary dependency changes.
- Never commit credentials, personal production data, production dumps or private keys. Use synthetic fixtures and redact artifacts.

## Verification and handoff

- Inspect the final diff and generated contracts. Run `quality:check` and checks selected for the impact; broaden testing only for a new failure or unresolved risk.
- For UI changes inspect the relevant loading, empty, error, success, open dialog and narrow-screen states in a browser. A build alone does not demonstrate usability.
- Record the source fingerprint, commands, outcomes, skipped checks and reasons. Source changes invalidate earlier evidence.
- If the user requests a manual trial first, write necessary tests and record their execution as deferred. Say implemented and ready for trial, not validated.
- Distinguish implemented, automatically tested, manually inspected, hardware tested and legally reviewed. Mocks do not establish hardware or statutory acceptance.
- Do not enable GitHub Actions, send external messages, perform hardware operations or publish changes without the applicable authorization.
- Handoff states affected repositories, completed work, remaining work and actual evidence. Preserve another agent's changes; reconcile shared contracts before completing.

## Limits of enforcement

Local hooks can be bypassed. Automated checks validate structure, references and selected executions; maintainers still review business meaning, assertion quality and new abstractions. CI is disabled until explicitly reactivated.
<!-- END GENERATED CONTRACT -->

## Repository guidance

Flutter Android hardware bridge; iOS requires physical validation. Keep ECR/Viva procedures in adapters and use the durable executor. Do not retry unknown fiscal/payment outcomes. Preserve device TLS keys, identities and OTA compatibility. Commands: flutter analyze, flutter test <file>, dart run tool/quality.dart. Hardware operations require explicit authorization.

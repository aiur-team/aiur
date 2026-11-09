---
title: Operator answer relay
artifact_readiness: implementation-ready
---

# Operator answer relay

An attended Executor must record a human's already-given answer without claiming to be the human or gaining decision authority. Add `operator-relay-answer` with an operator-enabled `executor.relay_operator_answers` flag, default false.

1. Extend `src/lib/aiur/decision_answer.ex` with `operator_relayed` attribution, a required verbatim operator quote and relayer identity. Include provenance in immutable hashes and durable decoding, omitting absent relay fields for backwards compatibility. Guard relay recording in `decision_store.ex` with live configuration; use existing answer delivery and operator supersede/moot semantics. Notify through the existing info-alert path after durable acceptance. Tests in `src/test/aiur/operator_relay_answer_test.exs` cover disabled/enabled recording, exact provenance after restart, delivery, operator revision/moot, idempotency and unchanged Executor refusal.
2. Add a dedicated relay CLI module and shared-engine dispatch, config schema/accessor, and attribution in Command detail/history. Extend engine and presenter tests. Update CLI/configuration/Commands docs, annotated templates, and aiur-run's attended-human workflow.

Relay answers follow operator authority; this does not widen Executor or supervisor authority/reversibility floors. Relay remains subject to version, response, idempotency and delivery-state guards. Existing operator revision can supersede delivered answers; existing supersede/moot remains constrained while delivery is in flight. Preserve those semantics.

Validate scoped compilation, formatting, affected tests, shell syntax and config-doc checks. Mutation-test each new behavior in an isolated worktree. Do not run destructive manual sandbox tests from an agent workspace.

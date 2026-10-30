# Executor hook ingestion (#7161)

Implement MP-E3-C1-T02 against the existing Session binding (C1-T01 is present).
The source refresh resolves historical router scopes to router pipelines and
route macros, HookEvents.normalize/1, SupervisorAuth and Endpoint Plug.Parsers.
No missing design choice or dependency remains.

## Units

1. Add HookToken using Fs.atomic_write and the instance-scoped SessionRecord
   path convention; ensure private directory and files, stable ensure and rotate.
   Add TranscriptPath and HookPayload: bounded allowlisted fields, explicit
   harness, both paths checked for root, regular file, owner and session basename.
   Reject symlinked ancestors as well as the leaf. Report drops through telemetry.
   Tests: hook_token_test.exs and hook_payload_test.exs in test/aiur/executor/.
2. Add SessionIngest after Session in application children. Cast before payload
   normalization so filesystem validation and binding calls cannot delay HTTP.
   Reject unattached, mismatched harness/session; rate limit each binding to 50/s;
   bind/rebind then touch/end and publish accepted events on executor_hook.
   Keep pid for the existing same-process rebind fence. Tests:
   test/aiur/executor/session_ingest_test.exs.
3. Add dedicated loopback bearer plug and route outside dashboard write/auth
   gates; authenticate before 202, return 405 for other authenticated methods.
   Harness comes exclusively from query parameters. Tests:
   test/aiur_web/executor_hook_controller_test.exs, including blocked worker,
   read-only mode, token failures and query/body confusion. Document endpoint.

## Risks and verification

Two files cannot be renamed as one filesystem transaction; each write is atomic,
with ensure repairing the header from the authoritative token. Serialise token
writers to prevent concurrent ensure/rotate mismatches. Do not log payloads.
Subagent transcript paths use agent_id for their basename identity.
Run affected tests, compile, format, lint, structural and pre-PR gates. Mutation
checks run in an isolated worktree and must fail each new behavior test. Real
CLI captures and smoke require an Executor-root run; list as post-deploy checks
without claiming those ran here.

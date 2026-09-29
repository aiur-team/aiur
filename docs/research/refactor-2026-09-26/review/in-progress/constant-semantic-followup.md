# Constant semantic follow-up

Frozen source: `3339b887196d5e9aefb273117a14bf33391ee41f`.
This is a targeted source check of the risk-bearing routes left by
`inline-literal-role-closure.json`. It does not turn the 870 role routes into
per-caller reviews. The paths and line numbers below refer to that frozen
snapshot; the census and role ledger preserve its source hashes.

| Candidate | Source check and disposition |
| --- | --- |
| GitHub poll branch strings | `github/ci_poll_batch.ex:155-190` and `github/comment_poll_batch.ex:193-227` repeat `branch_target_entry`, `guessed_branches`, `known_branch` and `open_pull_request_head_ref`, with the same candidate order. `github-a-09` and `dup-by-body-19` already own the larger behavioral finding; no new string finding. |
| Urgent event XML | `agent_runner/checkpoint_delivery.ex:94-99` and `agent_runner/queue_drain.ex:412-423` both replace `<aiur:events>` with its urgent variant after rendering. `agent-runtime-32` already owns the render-option proposal; no separate literal extraction. |
| Opaque digest grammar | `live_conversation.ex:546-551` generates `conversation:` and `projection:` plus 43 URL-safe Base64 characters. `live_conversation/source.ex:83-87` validates a conversation handle; `orchestrator/state.ex:645-648,675-679` validates projection and session digests with the same lexical shape. These are producer/consumer contracts with distinct prefixes and state boundaries. A future shared opaque-ID primitive must retain each allowed prefix and generation policy; the regex spelling alone is not a new finding. `agent-runtime-32` already flags inconsistent opaque hashing elsewhere. |
| Branch SHA grammar | `events/branch_ref_store.ex:455-465` and `orchestrator/push_routing.ex:1058-1074` each accept a 40-digit hex SHA (case-insensitive), validate ticket refs and lowercase the SHA. The former indexes persistent branch refs; the latter validates a blocker-unblock event and compares the ticket identifier. A low-level SHA validator is plausible, but merging these workflows would cross persistence and unblock policy. Too small as a standalone refactor finding without a broader branch-identity owner. |
| Write-probe filename | `build_gate.ex:767-783` and `config/codex_sandbox_policy.ex:225-241` each make `.aiur-write-probe-<pid>-<unique>` names and open exclusively. The former checks a lock directory and reports gate unavailability; the latter checks a configured sandbox root during config validation. The shared filename is incidental; error and cleanup contracts should be assessed with those owning modules before any extraction. |
| SQLite exclusive transaction | `asks_store.ex:16-31` and `repo_base.ex:838-851` use `BEGIN EXCLUSIVE` after a busy timeout and close in an `after` block. One locks Ask-store operations and recovers a torn tail; the other runs base-schema migration. The SQL token is SQLite syntax, while transaction scope and recovery policy differ. No common transaction helper is justified by the token. |
| Telemetry endpoint | `claude/telemetry.ex:416` constructs `/v1/logs`; `claude/telemetry/receiver.ex:36` accepts `POST /v1/logs`. This is an endpoint producer/receiver agreement, not duplicate logic. A shared route could prevent drift only if one owner can be used without coupling client and HTTP receiver. |
| GitHub mutation regex | `github/quota.ex:1243` and `github/request_log.ex:271` use the same mutation-start regex. `github-b-05` already identifies a larger inconsistency across five request classifiers, including different comment handling. Consolidate classification at that boundary; copying the regex to a common constant would preserve the incorrect disagreement. |

These checks found no sixth independent constant finding. The five provisional
source-backed findings in `dup-by-constant.json` remain the unit's output.
Further semantic certainty requires caller-by-caller review of the 870 routed
groups and dynamic/generated values; neither is claimed by this static unit.

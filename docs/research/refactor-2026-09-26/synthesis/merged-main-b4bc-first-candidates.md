# First focused refactor candidates at `main@b4bc11f`

These are read-only source checks. Neither is authorized as a broad subsystem
rewrite or as a measured saving.

## Pause containment after a between-turn acknowledgement (`agent-runtime-01`)

`agent_runner/queue_drain.ex:40-57,130-146` has two correlated
`{:pause_agent, request_id, generation}` receives that report `:paused`
without confirming the armed containment. The queued-turn result path does
confirm it. An armed entry can reach its five-second fallback and reap an
otherwise healthy idle worker. A focused test should enter each QueueDrain
wait path, send a correlated pause, observe the `:paused` acknowledgement,
and assert the registered containment mode becomes `:paused`; both paths
currently leave it `:armed`.

There is also an ordering race: `OperatorMessages.send_running_control_message`
queues the pause before `PauseResume.accept_admitted_control_request` arms
containment (`operator_messages.ex:1137`, `pause_resume.ex:1813`). A worker-side
confirm can run first and become a no-op on the still-active entry. The
Orchestrator's correlated `:worker_control_state` acknowledgement path
(`orchestrator.ex:168-170`, `pause_resume.ex:1005-1101`) applies the pause
evidence but currently does not confirm containment. A robust fix must prove
both orders. One possible seam is a generation-fenced confirm when the
Orchestrator accepts the matched pause acknowledgement, after its current
call has armed containment. Capture the containment handle from the arm;
looking up by issue identifier at acknowledgement time could affect a
successor worker. Test both acknowledgement-before-arm scheduling and a
replacement worker so a stale pause cannot confirm the new containment.

## Accept the documented noop-turn override (`platform-misc-01`)

`config/schema/agent.ex:191` declares `max_consecutive_noop_turns` with
default three, but `Agent.changeset/2` omits it from the cast list at
`:280-323`. `Schema.parse/1` therefore discards an operator override and
`Config.agent_max_consecutive_noop_turns/0` still returns three to
`TurnLoop.noop_turn_cap/1`. None of the six shipped configs sets the key, so
this is an opt-in configuration defect, not a default-run failure.

A minimal regression test parses `%{"agent" =>
%{"max_consecutive_noop_turns" => 0}}` and asserts the parsed value is zero;
it fails on current main. Also reject a negative value. Existing loop tests
pass a direct keyword override and cannot detect the config error. The
configuration reference already documents zero as the opt-out, so restoring
that behavior needs no new page.

## Complete classified GitHub comments (`github-a-04`)

`src/lib/aiur/github/comments.ex:124-141` asks `Transport.fetch_json_list/4`
for `/issues/:number/comments?per_page=100`, which does not follow a `Link`
header. The classified result reaches `AgentRunner.CommentContext` on cold
start (`agent_runner/comment_context.ex:29-46,183-220,252-265`), including
both ticket and PR comments, the latest `## Agent Workpad` cutoff, and trust
classification. A later page can therefore be absent from the bootstrap
digest, even if it contains a trusted instruction or newer workpad.

The same module already has a complete paginated reader:
`Comments.fetch_issue_comments_conditional/2` (`comments.ex:81-122,150-169`).
A focused fix should retain the classified API and map its complete result
through the existing CODEOWNERS classification, with no second paginator.
Strip `:etag` or handle `:not_modified` explicitly because bootstrap needs a
materialized list. Preserve the `classified_issue_comments` caller attribution
used by `github-cost`; the complete reader currently builds its request
without that caller tag.

Behavior gate: return page one with a `rel="next"` Link and page two with a
distinct trusted comment. Assert both appear in order and the second is
authoritative. Then put the latest workpad and a trusted directive on page
two and assert `CommentContext` applies that cutoff and includes the
directive. The current classified reader should fail these tests before a
production change.

## Reduce Codex event path duplication in place

`src/lib/aiur/codex/event_humanizer.ex:322-359,471-509` lists adjacent
string and atom paths for deltas, token usage and reasoning focus.
`EventHumanizerHelpers.map_path/2` already tries both key spellings at each
segment (`event_humanizer_helpers.ex:5-13,91-114`), but an exact key whose
value is `nil` or `false` blocks that fallback. The humanizer's outer `||`
then tries the mirrored whole path and can choose a different value. Removing
all atom paths without testing that collision changes the result.

The small safe candidate is to pair each adjacent path and let
`extract_first_path/2` evaluate `map_path(payload, string_path) ||
map_path(payload, atom_path)` in the original order. This may remove about 32
physical lines; count the final diff before claiming a reduction. Differential
tests must compare the original output across string-only, atom-only, mixed
nested keys, colliding keys with `nil` and `false` at leaf and intermediate
segments, both keys truthy, and earlier false/nil candidates. Exercise
`thread/started`, streaming delta, token count and reasoning focus. Abandon
the change if it grows code or changes the emitted content.

# First focused refactor candidates at `main@b4bc11f`

These are read-only source checks. Neither is authorized as a broad subsystem
rewrite or as a measured saving.

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

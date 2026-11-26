# Sibling protocol contract

`protocol-1.1.0.ndjson` records `claude-app-server` revision `b1ea979`, whose
package version is 1.1.0. Each row names its scenario, direction relative to
Aiur, and JSON-RPC message. IDs, timestamps, workspace, client version and the
live dynamic-tool catalog use placeholders.

Build a sibling checkout, then run from this repository:

```sh
AIUR_CLAUDE_DIR=/path/to/claude-app-server scripts/record-aiur-claude-protocol.sh
```

The checker uses the built sibling dispatcher, its fake Claude CLI subprocess,
and the real MCP socket bridge. It disables utilization fetching and requires no
Claude credentials. It does not exercise the sibling's CLI transport launcher.
Review drift before explicitly refreshing the fixture with `--write`.

Tag `v1.1.0` lacks the two `provider_error` fields in the provenance scenario;
the checker deliberately reports that difference. Replay tests cover both
legacy failure handling and provenance. Unknown-notification and legacy quota
probes are synthetic additions in the test, outside the recorded conversation.
The advertised `steer` capability is recorded; Aiur must never send it.

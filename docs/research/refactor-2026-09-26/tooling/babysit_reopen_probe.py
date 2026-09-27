"""Probe only the frozen disposition function; no GitHub, filesystem state or watcher."""
import ast
import json
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
tree = ast.parse(source)
node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_apply_dispositions")
namespace = {"DISPOSITION_OPEN": "open", "DISPOSITION_DISPATCHED": "dispatched", "DISPOSITION_NEEDS_HUMAN": "needs-human"}
exec(compile(ast.Module(body=[node], type_ignores=[]), "<frozen-disposition-function>", "exec"), namespace)
apply = namespace["_apply_dispositions"]
identity = lambda item: [item["last_comment_id"], item["last_comment_at"]]
baseline = {"thread_id": "t", "last_comment_id": "reply-1", "last_comment_at": "time-1"}
parked = {"t": {**baseline, "disposition": "needs-human", "acted_identity": identity(baseline)}}
same, actions, count = apply([baseline], "thread_id", parked, identity)
assert same["t"]["disposition"] == "needs-human" and not actions and count == 1
changed = {**baseline, "last_comment_id": "reply-2", "last_comment_at": "time-2"}
reopened, actions, count = apply([changed], "thread_id", parked, identity)
assert reopened["t"]["disposition"] == "open" and actions == [changed] and count == 0
lazy, actions, count = apply([baseline], "thread_id", {"t": {"disposition": "needs-human"}}, identity)
assert lazy["t"]["acted_identity"] == identity(baseline) and not actions and count == 1
print(json.dumps({"unchanged_identity": "parked", "changed_identity": "automatically_reopened", "first_observation": "baseline_adopted_without_reopening", "scope": "isolated frozen function; no API, actor attribution or end-to-end watcher verification"}, indent=2))

import json, subprocess, sys, os
out = sys.argv[1]
env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_TOKEN", "GH_TOKEN")}
FIELDS = '''number title createdAt closedAt state stateReason
 blockedBy(first:30){nodes{number}} blocking(first:30){nodes{number}}
 parent{number}
 labels(first:40){nodes{name}}
 closedByPullRequestsReferences(first:10, includeClosedPrs:true){nodes{number createdAt isDraft mergedAt closedAt state author{login} baseRefName
   timelineItems(first:30, itemTypes:[READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT]){nodes{__typename ... on ReadyForReviewEvent{createdAt} ... on ConvertToDraftEvent{createdAt}}}}}
 timelineItems(first:200, itemTypes:[LABELED_EVENT, UNLABELED_EVENT, CLOSED_EVENT, REOPENED_EVENT]){nodes{__typename ... on LabeledEvent{createdAt label{name}} ... on UnlabeledEvent{createdAt label{name}} ... on ClosedEvent{createdAt stateReason} ... on ReopenedEvent{createdAt}}}'''
def gql(q, **vars):
    args = ["gh", "api", "graphql", "-f", "query=" + q]
    for k, v in vars.items():
        if v is not None: args += ["-f", "%s=%s" % (k, v)]
    r = subprocess.run(args, capture_output=True, text=True, env=env, cwd="/tmp", timeout=300)
    if r.returncode != 0: raise SystemExit(r.stderr[:2000])
    return json.loads(r.stdout)
issues = {}
# Split search window by day to stay under the 1000 result cap.
days = ["2026-10-0%d" % d for d in range(4, 10)] + ["2026-10-10"]
for i in range(len(days) - 1):
    cursor = None
    while True:
        q = 'query($c:String){ search(type:ISSUE, first:50, after:$c, query:"repo:aiur-team/aiur is:issue updated:%s..%s"){ issueCount pageInfo{hasNextPage endCursor} nodes{ ... on Issue { %s } } } }' % (days[i], days[i+1], FIELDS)
        d = gql(q, c=cursor)["data"]["search"]
        for n in d["nodes"]:
            if n: issues[n["number"]] = n
        if not d["pageInfo"]["hasNextPage"]: break
        cursor = d["pageInfo"]["endCursor"]
    print(days[i], d["issueCount"], len(issues), file=sys.stderr)
# Fetch any blocker that was not in the window.
need = set()
for n in list(issues.values()):
    for b in n["blockedBy"]["nodes"]: need.add(b["number"])
need -= set(issues)
for num in sorted(need):
    q = 'query($n:Int!){ repository(owner:"aiur-team", name:"aiur"){ issue(number:$n){ %s } } }' % FIELDS
    r = subprocess.run(["gh","api","graphql","-f","query="+q,"-F","n=%d"%num], capture_output=True, text=True, env=env, cwd="/tmp")
    try: issues[num] = json.loads(r.stdout)["data"]["repository"]["issue"]
    except Exception: print("fail", num, r.stderr[:200], file=sys.stderr)
json.dump(issues, open(out, "w"))
print(len(issues), "issues", file=sys.stderr)

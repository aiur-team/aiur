import json, subprocess, sys, os
I = json.load(open(sys.argv[1])); out = sys.argv[2]
env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_TOKEN", "GH_TOKEN")}
nums = sorted(int(k) for k, v in I.items() if v and v["blockedBy"]["nodes"])
res = {}
for i in range(0, len(nums), 25):
    chunk = nums[i:i+25]
    body = " ".join('i%d:issue(number:%d){ timelineItems(first:60, itemTypes:[BLOCKED_BY_ADDED_EVENT, BLOCKED_BY_REMOVED_EVENT]){nodes{__typename ... on BlockedByAddedEvent{createdAt blockingIssue{number}} ... on BlockedByRemovedEvent{createdAt blockingIssue{number}}}}}' % (n, n) for n in chunk)
    q = 'query { repository(owner:"aiur-team", name:"aiur"){ %s } }' % body
    r = subprocess.run(["gh", "api", "graphql", "-f", "query=" + q], capture_output=True, text=True, env=env, cwd="/tmp")
    d = json.loads(r.stdout)["data"]["repository"]
    for k, v in d.items(): res[int(k[1:])] = v["timelineItems"]["nodes"]
json.dump(res, open(out, "w")); print(len(res))

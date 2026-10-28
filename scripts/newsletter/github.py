"""Bounded, explicitly paged GitHub reads through the governed gh command."""
import json
import re
import subprocess


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    if result.returncode:
        # Keep credentials and remote diagnostic payloads out of snapshots.
        raise RuntimeError(f"{args[0]} {args[1]} failed (exit {result.returncode})")
    return result.stdout


ISSUE = '''id number title state stateReason createdAt closedAt
 labels(first:100) { nodes { name } pageInfo { hasNextPage } }'''
PR = '''number title body headRefName mergedAt mergeCommit { oid }
 closingIssuesReferences(first:10) { nodes { number } }'''


class GitHub:
    def __init__(self, repo, run=command):
        self.repo = repo
        self.owner, self.name = repo.split("/")
        self.run = run
        self.cost = 0
        self.calls = 0
        self.cost_complete = True

    def query(self, query, **variables):
        # Each query below has at most 100 one-page connections (< 2 points).
        # Reserve two points per request even after transport failures.
        if self.calls >= 24:
            raise RuntimeError("GraphQL request ceiling reached (<50 point budget)")
        self.calls += 1
        args = ["gh", "api", "graphql", "-f", "query=" + query]
        for key, value in variables.items():
            args.extend(["-F" if value is None else "-f", f"{key}={value if value is not None else 'null'}"])
        try:
            result = json.loads(self.run(args))
        except (RuntimeError, OSError, subprocess.SubprocessError, ValueError):
            self.cost_complete = False
            raise
        cost = (result.get("data") or {}).get("rateLimit", {}).get("cost")
        if cost is None:
            self.cost_complete = False
        else:
            self.cost += cost
        if result.get("errors") or not isinstance(result.get("data"), dict):
            raise RuntimeError("GitHub returned GraphQL errors")
        return result["data"]

    def pages(self, fetch):
        cursor = None
        seen = set()
        while True:
            page = fetch(cursor)
            yield from page["nodes"]
            info = page["pageInfo"]
            if not info["hasNextPage"]:
                return
            cursor = info["endCursor"]
            if not cursor or cursor in seen:
                raise RuntimeError("GitHub repeated a pagination cursor")
            seen.add(cursor)

    def phase_labels(self):
        query = '''query($owner:String!,$name:String!,$cursor:String) {
 repository(owner:$owner,name:$name) { labels(first:100,query:"phase:",after:$cursor) {
 nodes { name } pageInfo { hasNextPage endCursor } } } rateLimit { cost } }'''
        return [n["name"] for n in self.pages(lambda c: self.query(
            query, owner=self.owner, name=self.name, cursor=c)["repository"]["labels"])
                if n["name"].startswith("phase:")]

    def search(self, expression, fields, kind):
        query = '''query($q:String!,$cursor:String) { search(query:$q,type:ISSUE,first:100,after:$cursor) {
 issueCount nodes { ... on %s { %s } } pageInfo { hasNextPage endCursor }
 } rateLimit { cost } }''' % (kind, fields)

        def fetch(cursor):
            page = self.query(query, q=f"repo:{self.repo} {expression}", cursor=cursor)["search"]
            if page["issueCount"] > 1000:
                raise RuntimeError("Search exceeds GitHub's 1000-result limit")
            return page
        return list(self.pages(fetch))

    def issues(self, numbers):
        result = {}
        numbers = sorted(set(numbers))
        for start in range(0, len(numbers), 100):
            aliases = " ".join(f"i{n}:issue(number:{n}) {{ {ISSUE} }}" for n in numbers[start:start+100])
            query = '''query($owner:String!,$name:String!) { repository(owner:$owner,name:$name) {
 %s } rateLimit { cost } }''' % aliases
            nodes = self.query(query, owner=self.owner, name=self.name)["repository"]
            for node in nodes.values():
                if node is None or node["labels"]["pageInfo"]["hasNextPage"]:
                    raise RuntimeError("Issue or complete labels unavailable")
                result[node["number"]] = node
        return result


def closing_issue(pr):
    refs = pr["closingIssuesReferences"]["nodes"]
    if refs:
        return refs[0]["number"]
    match = re.search(r"(?:closes|fixes|resolves) #([0-9]+)", pr.get("body", ""), re.I)
    if not match:
        match = re.match(r"^aiur/([0-9]+)", pr.get("headRefName", ""))
    return int(match[1]) if match else None

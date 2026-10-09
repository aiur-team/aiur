#!/usr/bin/env python3
"""Census current direct membership of every build-order-labelled root via governed gh."""
import argparse
import datetime
import json
import statistics
import subprocess

QUERY = """query($owner:String!, $repo:String!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    issues(first:100, labels:["build-order"], after:$cursor,
           orderBy:{field:CREATED_AT,direction:DESC}) {
      totalCount pageInfo {hasNextPage endCursor}
      nodes {number title state createdAt subIssues(first:1) {totalCount}}
    }
  }
  rateLimit {cost}
}"""


def census(repository, run=subprocess.check_output):
    owner, repo = repository.split("/", 1)
    roots, cursor, total, points = [], None, None, 0
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    while True:
        args = ["gh", "api", "graphql", "-f", "query=" + QUERY,
                "-f", "owner=" + owner, "-f", "repo=" + repo]
        if cursor:
            args += ["-f", "cursor=" + cursor]
        response = json.loads(run(args, text=True))
        if response.get("errors"):
            raise ValueError(response["errors"])
        page = response["data"]["repository"]["issues"]
        if total is not None and total != page["totalCount"]:
            raise ValueError("Root population changed during census; rerun")
        total = page["totalCount"]
        roots.extend(page["nodes"])
        points += response["data"]["rateLimit"]["cost"]
        info = page["pageInfo"]
        if not info["hasNextPage"]:
            break
        if not info["endCursor"] or info["endCursor"] == cursor:
            raise ValueError("Missing or repeated pagination cursor")
        cursor = info["endCursor"]
    if len(roots) != total or len({r["number"] for r in roots}) != total:
        raise ValueError("Incomplete or duplicate root population; rerun")
    counts = [r["subIssues"]["totalCount"] for r in roots]
    return {"repository": repository, "started_at": started,
            "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "roots": roots, "root_count": total, "membership_links": sum(counts),
            "median_members": statistics.median(counts) if counts else None,
            "largest_root": max(counts) if counts else None,
            "query_points": points}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="aiur-team/aiur")
    print(json.dumps(census(parser.parse_args().repo), indent=2))

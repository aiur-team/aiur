#!/usr/bin/env bash
# MPG-101: characterise GitHub ref compare-and-set for ticket ownership.
# Usage: SANDBOX_REPO=owner/throwaway-repo scripts/spikes/github_ownership_cas.sh
# Needs a token (gh auth) with contents:write on a THROWAWAY repo. Creates refs
# under refs/aiur/owners/ and refs/heads/aiur-owner/ named by a per-run suffix,
# and deletes them at the end.
# Prints `STEP | status | type | message` per call.
# Exit 1 if the second create in step 2 succeeds, or any step-7 round has !=1 winner.
# Exit 2 on setup problems.
set -uo pipefail
repo="${SANDBOX_REPO:?set SANDBOX_REPO=owner/repo (a throwaway sandbox)}"
case "$repo" in */aiur|aiur-team/*) echo "refusing to run against $repo" >&2; exit 2;; esac
zero=0000000000000000000000000000000000000000
run="$(date -u +%Y%m%dT%H%M%SZ)-$$"
echo "# MPG-101 run $run repo=$repo date=$(date -u +%F)"

# Split `gh api -i` output into $status and $body.
split() {
  status="$(printf '%s\n' "$1" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p')"
  body="$(printf '%s\n' "$1" | sed '1,/^\r\?$/d')"
  [ -n "$status" ] || { status=000; body="$1"; }
}
# record STEP : prints the line for the current $status/$body.
record() {
  printf '%s | %s | %s | %s\n' "$1" "$status" \
    "$(printf '%s' "$body" | jq -r '(.errors[0].type // .message // "none") | tostring' 2>/dev/null || echo '?')" \
    "$(printf '%s' "$body" | jq -r '(.errors[0].message // .message // "ok") | tostring' 2>/dev/null || printf '%s' "$body" | head -c 200)"
}
call() { local step="$1"; shift; split "$(gh api -i "$@" 2>&1)"; record "$step"; }
# updateRefs body as JSON on stdin: `-F i={...}` would send the input as a string.
payload() { # refname beforeOid afterOid
  jq -n --arg rid "$rid" --arg n "$1" --arg b "$2" --arg a "$3" \
    '{query:"mutation($i:UpdateRefsInput!){updateRefs(input:$i){clientMutationId}}",variables:{i:{repositoryId:$rid,refUpdates:[{name:$n,beforeOid:$b,afterOid:$a}]}}}'
}
gql() { # STEP refname beforeOid afterOid
  split "$(payload "$2" "$3" "$4" | gh api graphql -i --input - 2>&1)"
  record "$1"
  gql_failed="$(printf '%s' "$body" | jq -r 'has("errors")' 2>/dev/null || echo true)"
}

rid="$(gh api graphql -f query='query($o:String!,$n:String!){repository(owner:$o,name:$n){id}}' \
  -f o="${repo%/*}" -f n="${repo#*/}" -q .data.repository.id)" || exit 2
# Step 1: tree + commits holding owner.json (c2 child of c1; cx an unrelated root).
blob="$(gh api "repos/$repo/git/blobs" -f content="{\"owner\":\"$run\"}" -f encoding=utf-8 -q .sha)" || exit 2
tree="$(gh api "repos/$repo/git/trees" -f 'tree[][path]=owner.json' -f 'tree[][mode]=100644' -f 'tree[][type]=blob' -f "tree[][sha]=$blob" -q .sha)" || exit 2
c1="$(gh api "repos/$repo/git/commits" -f message=c1 -f tree="$tree" -q .sha)" || exit 2
c2="$(gh api "repos/$repo/git/commits" -f message=c2 -f tree="$tree" -f "parents[]=$c1" -q .sha)" || exit 2
cx="$(gh api "repos/$repo/git/commits" -f message=cx -f tree="$tree" -q .sha)" || exit 2
echo "1 create tree+commits | 201 | none | tree=$tree c1=$c1 c2=$c2 cx=$cx"

second_create_ok=0
gql "2 a graphql create #1 aiur/owners" "refs/aiur/owners/$run" $zero "$c1"
gql "2 b graphql create #2 aiur/owners" "refs/aiur/owners/$run" $zero "$c1"
[ "$gql_failed" = false ] && second_create_ok=1
gql "3 a graphql advance correct beforeOid" "refs/aiur/owners/$run" "$c1" "$c2"
gql "3 b graphql advance stale beforeOid" "refs/aiur/owners/$run" "$c1" "$cx"
gql "4 a graphql create #1 heads/aiur-owner" "refs/heads/aiur-owner/$run" $zero "$c1"
gql "4 b graphql create #2 heads/aiur-owner" "refs/heads/aiur-owner/$run" $zero "$c1"
gql "4 c graphql advance correct beforeOid" "refs/heads/aiur-owner/$run" "$c1" "$c2"
gql "4 d graphql advance stale beforeOid" "refs/heads/aiur-owner/$run" "$c1" "$cx"

rest="refs/aiur/owners/$run-rest"
call "5 a REST POST /git/refs #1" "repos/$repo/git/refs" -f ref="$rest" -f sha="$c1"
call "5 b REST POST /git/refs #2" "repos/$repo/git/refs" -f ref="$rest" -f sha="$c1"
call "5 c REST PATCH force=false ff c1->c2" -X PATCH "repos/$repo/git/$rest" -f sha="$c2" -F force=false
call "5 d REST PATCH force=false ff again (not a CAS)" -X PATCH "repos/$repo/git/$rest" -f sha="$c2" -F force=false
call "5 e REST PATCH force=false non-ff to cx" -X PATCH "repos/$repo/git/$rest" -f sha="$cx" -F force=false

url="repos/$repo/git/ref/${rest#refs/}"
call "6 a read plain" "$url"
etag="$(gh api -i "$url" 2>/dev/null | tr -d '\r' | sed -n 's/^[Ee][Tt]ag: //p')"
call "6 b read Cache-Control: no-cache" -H 'Cache-Control: no-cache' "$url"
call "6 c read If-None-Match (expect 304)" -H "If-None-Match: $etag" "$url"

# Step 7: concurrent creates on one fresh ref; exactly one winner per round is a go.
rounds="${ROUNDS:-20}" racers=3 bad_rounds=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
race_create() { # ref outfile
  payload "$1" "$zero" "$c1" | gh api graphql --input - >"$2" 2>&1
}
raced=()
for n in $(seq "$rounds"); do
  ref="refs/aiur/owners/$run-race$n"; raced+=("$ref")
  for k in $(seq "$racers"); do race_create "$ref" "$tmp/$n.$k" & done
  wait
  wins=0
  for k in $(seq "$racers"); do
    if jq -e 'has("errors")|not' "$tmp/$n.$k" >/dev/null 2>&1; then wins=$((wins+1))
    else echo "7 round $n loser | $(jq -r '(.errors[0].type // "?")+" | "+(.errors[0].message // "?")' "$tmp/$n.$k" 2>/dev/null || head -c 200 "$tmp/$n.$k")"; fi
  done
  echo "7 round $n | winners=$wins"
  [ "$wins" = 1 ] || bad_rounds=$((bad_rounds+1))
done
echo "7 summary | rounds=$rounds racers=$racers bad_rounds=$bad_rounds"

# Step 8: enumerate claims by prefix (REST and GraphQL), then clean up with DELETE.
call "8 a REST matching-refs aiur/owners/" "repos/$repo/git/matching-refs/aiur/owners/$run"
echo "8 a count | $(printf '%s' "$body" | jq 'length' 2>/dev/null || echo '?') (expect $((rounds+2)))"
split "$(gh api graphql -i -f query='query($o:String!,$n:String!,$p:String!){repository(owner:$o,name:$n){refs(refPrefix:$p,first:100){nodes{name}}}}' \
  -f o="${repo%/*}" -f n="${repo#*/}" -f p="refs/aiur/owners/" 2>&1)"; record "8 b graphql refs(refPrefix:)"
call "8 c REST DELETE one claim" -X DELETE "repos/$repo/git/refs/aiur/owners/$run-race1"

for r in "refs/aiur/owners/$run" "$rest" "refs/heads/aiur-owner/$run" "${raced[@]:1}"; do
  gh api -X DELETE "repos/$repo/git/$r" >/dev/null 2>&1 || echo "# cleanup failed: $r"
done
if [ "$second_create_ok" = 1 ]; then
  echo "FAIL: second graphql create succeeded; no atomic create-if-absent" >&2
  exit 1
fi
[ "$bad_rounds" = 0 ] || { echo "FAIL: $bad_rounds race round(s) without exactly one winner" >&2; exit 1; }

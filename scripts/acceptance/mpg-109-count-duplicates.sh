#!/usr/bin/env bash
# MPG-109 duplicate counters. Usage:
#   rows <workspace.root>/<repo> <gateway> [T0 T1]   TSV: ticket gateway start end
#   overlaps <rows.tsv...>                    cross-gateway overlapping tickets (JSON array)
#   same-overlaps <rows.tsv...>               same-gateway overlapping tickets (JSON array)
#   refs <repo-dir>  ownership-ref duplicates/skips; writes refs/aiur-check/* into that clone (use a scratch clone)
#   prs <owner/repo> <T0> <T1>                tickets with more than one PR
set -euo pipefail

rows() {
  local root=$1 gw=$2 a=${3:-0} b=${4:-9999} d t f
  for d in "$root"/*/; do
    t=$(basename "$d"); f="$d/logs/agent.ndjson"; [ -f "$f" ] || continue
    jq -s -r --arg t "$t" --arg g "$gw" '
      [.[]|select(.event=="session_started").timestamp] as $s | (.[-1].timestamp) as $L
      | range(0;$s|length) as $i | [$t,$g,$s[$i],($s[$i+1]//$L)] | @tsv' "$f"
  done | awk -F'\t' -v a="$a" -v b="$b" '$4>=a && $3<=b'
}

# $1 is the jq comparison: "!=" for cross-gateway, "==" for same-gateway.
overlap() {
  local op=$1; shift
  cat "$@" | jq -R -s -c --arg op "$op" '
    split("\n")|map(select(length>0)|split("\t")|{t:.[0],g:.[1],s:.[2],e:.[3]})|group_by(.t)
    |map(. as $r|[range(0;length) as $i|range($i+1;length) as $j
      |select((($r[$i].g==$r[$j].g)==($op=="=="))
        and $r[$i].s<$r[$j].e and $r[$j].s<$r[$i].e)|$r[$i].t]|unique)|add//[]'
}

refs() {
  cd "$1"
  local sha ref n c
  git ls-remote origin 'refs/aiur/owners/*' | while read -r sha ref; do
    n=${ref##*/}
    git fetch -q origin "$ref:refs/aiur-check/$n" 2>/dev/null
    git log --format=%H "refs/aiur-check/$n" -- owner.json | while read -r c; do
      git show "$c:owner.json" | jq -c '{ticket,epoch,previous_epoch,gateway_id,reason,at}'
    done
  done | jq -s -c 'group_by(.ticket)|map({t:.[0].ticket,
    dup:([group_by(.epoch)[]|select(length>1 and ([.[].gateway_id]|unique|length)>1)]|length),
    skip:([.[]|select(.previous_epoch!=null and .previous_epoch+1!=.epoch)]|length)})
    |map(select(.dup>0 or .skip>0))'
}

prs() {
  gh pr list -R "$1" --state all --search "created:$2..$3" --limit 200 --json number,headRefName,body,createdAt \
    | jq -r '.[]|[(.body|capture("Closes #(?<n>[0-9]+)").n // "none"),.number,.headRefName]|@tsv' \
    | sort | awk -F'\t' '$1!="none"{c[$1]++; l[$1]=l[$1]" #"$2} END{for(k in c) if(c[k]>1) print k, l[k]}'
}

cmd=${1:-}; shift || true
case $cmd in
  rows) rows "$@" ;;
  overlaps) overlap '!=' "$@" ;;
  same-overlaps) overlap '==' "$@" ;;
  refs) refs "$@" ;;
  prs) prs "$@" ;;
  *) echo "usage: $0 rows|overlaps|same-overlaps|refs|prs ..." >&2; exit 2 ;;
esac

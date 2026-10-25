# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
# The number a write mutates. Pull requests and issues share one number space on
# GitHub, so a comment posted through `gh issue comment 2073` changes what
# `gh pr view 2073 --json comments` would answer. Both directories are marked.
case "$command_key" in
  "pr create"|"issue create") cache_write_id=collection ;;
  "pr "*|"issue "*)
    if cache_numeric "$positional_three"; then cache_write_id=$positional_three; fi
    ;;
esac

if [ -n "$cache_root" ] && [ "$direction" = write ] && [ "${1:-}" = api ] && [ -z "$cache_write_id" ]; then
  cache_write_endpoint=$(api_command_endpoint "$@") || cache_write_endpoint=
  cache_write_endpoint=${cache_write_endpoint#/}
  cache_write_endpoint=${cache_write_endpoint%%\?*}
  case "$cache_write_endpoint" in
    repos/*/*/issues/*|repos/*/*/pulls/*)
      cache_write_rest=${cache_write_endpoint#repos/}
      cache_write_owner=${cache_write_rest%%/*}
      cache_write_rest=${cache_write_rest#*/}
      cache_write_repo=${cache_write_rest%%/*}
      cache_write_rest=${cache_write_rest#*/}
      cache_write_rest=${cache_write_rest#*/}
      cache_write_number=${cache_write_rest%%/*}
      if cache_valid_slug "$cache_write_owner/$cache_write_repo"; then
        cache_owner=$cache_write_owner
        cache_repo_name=$cache_write_repo

        if cache_numeric "$cache_write_number"; then
          cache_write_id=$cache_write_number
        else
          # `issues/comments/<id>`, `pulls/comments/<id>`, `issues/events/<id>`:
          # a subresource whose own id is not an issue or pull request number.
          # The agent workpad is edited through exactly this shape.
          cache_write_id=subresource
        fi
      fi
      unset cache_write_rest cache_write_owner cache_write_repo cache_write_number
      ;;
    repos/*/*/issues|repos/*/*/pulls)
      cache_write_rest=${cache_write_endpoint#repos/}
      cache_write_owner=${cache_write_rest%%/*}
      cache_write_rest=${cache_write_rest#*/}
      cache_write_repo=${cache_write_rest%%/*}
      if cache_valid_slug "$cache_write_owner/$cache_write_repo"; then
        cache_owner=$cache_write_owner
        cache_repo_name=$cache_write_repo
        cache_write_id=collection
      fi
      unset cache_write_rest cache_write_owner cache_write_repo
      ;;
  esac
  unset cache_write_endpoint
fi

if [ -n "$cache_root" ]; then
  cache_started_at=$(date -u +%s 2>/dev/null || printf '')
  case "$cache_started_at" in
    ''|*[!0-9]*) cache_root= ;;
  esac
fi

# `cache_now` is what freshness is measured against. It starts equal to the
# process's start and is re-sampled only by a coalesced follower, which is the
# one caller for whom "now" has genuinely moved since it started.
cache_now=${cache_started_at:-0}

if [ -n "$cache_root" ] && [ -n "$cache_owner" ] && [ -n "$cache_repo_name" ]; then
  # Down-cased, exactly as `Aiur.GitHub.ResourceStore.key/4` does, because the
  # daemon and this wrapper must name one repository one way. `-R AIUR-Team/Aiur`
  # and a webhook's `aiur-team/aiur` are the same repository; filed apart, the
  # daemon would retire entries no agent reads while agents keep serving the
  # ones it meant to retire — wrong in the one direction a cache may not be.
  if command -v tr >/dev/null 2>&1; then
    cache_identity=$(printf '%s/%s' "$cache_owner" "$cache_repo_name" | tr '[:upper:]' '[:lower:]')
    case "$cache_identity" in
      ?*/?*)
        cache_owner=${cache_identity%%/*}
        cache_repo_name=${cache_identity#*/}
        ;;
      *) cache_root= ;;
    esac
    unset cache_identity
  else
    # No `tr`, no way to guarantee one spelling. Caching nothing is the safe
    # answer; a half-shared store is worse than none.
    cache_root=
  fi
fi

if [ -n "$cache_root" ] && [ -n "$cache_owner" ] && [ -n "$cache_repo_name" ]; then
  cache_repo_dir=$cache_root/v1/$cache_owner/$cache_repo_name
fi

if [ "$cache_reads" -eq 1 ] && [ -n "$cache_repo_dir" ] && [ -n "$cache_kind" ] && [ -n "$cache_id" ]; then
  cache_shape=$(cache_material "$@" | cache_fingerprint) || cache_shape=
  if cache_valid_digest "$cache_shape"; then
    cache_entry_dir=$cache_repo_dir/$cache_kind/$cache_id
    cache_body=$cache_entry_dir/$cache_shape.body
    cache_meta=$cache_entry_dir/$cache_shape.meta
  else
    cache_shape=
  fi
fi

if [ -n "$agent_quota_dir" ]; then cache_events_file=$agent_quota_dir/agent-cache.tsv; fi

# U8 attribution and U9's debug page read this: one row per cacheable
# invocation, so agent-side effectiveness is a counted fact rather than an
# inference from falling request rates.
cache_record() {
  [ -n "$cache_events_file" ] || return 0

  cache_events_size=0
  if [ -f "$cache_events_file" ]; then
    cache_events_size=$(wc -c < "$cache_events_file" 2>/dev/null || printf '0')
  fi
  case "$cache_events_size" in
    ''|*[!0-9]*) cache_events_size=0 ;;
  esac
  if [ "$cache_events_size" -gt 1048576 ]; then
    # Timestamped rotations retain the complete 24-hour measurement window.
    # The pid keeps simultaneous writers from replacing one another's archive;
    # row timestamps, not filenames, decide which samples enter the ratio.
    mv -f "$cache_events_file" "$cache_events_file.$cache_started_at.$$" 2>/dev/null || true

    # Pruning is outside the call's output descriptors and keeps a one-hour
    # safety margin beyond the reader's window. `-mmin` and `-delete` are
    # non-POSIX, so this is gated exactly as `cache_prune` gates its own use of
    # them: on a host without GNU/BSD find the prune is a no-op rather than a
    # silent failure that lets archives accumulate.
    if command -v find >/dev/null 2>&1; then
      (
        find "$agent_quota_dir" -type f -name 'agent-cache.tsv.*' -mmin +1500 -delete || true
      ) >/dev/null 2>&1 &
    fi
  fi

  # Sixth column: the miss reason, written on every miss (#2299). Hits, stores
  # and coalesced replays are 5-column rows by design.
  if [ -n "${2:-}" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cache_started_at" "$consumer" "$1" "${cache_kind:-unknown}" "${cache_id:-unknown}" "$2" \
      >> "$cache_events_file" 2>/dev/null || true
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$cache_started_at" "$consumer" "$1" "${cache_kind:-unknown}" "${cache_id:-unknown}" \
      >> "$cache_events_file" 2>/dev/null || true
  fi
  unset cache_events_size
  return 0
}

# Reads use the shell's own `read` rather than `sed` so a hit spends no
# subprocess on freshness at all. #1984 measures the broker at 250-450ms and
# two `python3` spawns per call; a cache that added its own spawns to every
# lookup would hand back what it saved.
cache_marker_at() {
  [ -f "$1" ] || return 0

  cache_marker_value=
  IFS= read -r cache_marker_value < "$1" 2>/dev/null || cache_marker_value=
  case "$cache_marker_value" in
    ''|*[!0-9]*) cache_marker_value=0 ;;
  esac
  if [ "$cache_marker_value" -gt "$cache_invalidated_at" ]; then cache_invalidated_at=$cache_marker_value; fi
  unset cache_marker_value
  return 0
}

cache_lookup() {
  cache_miss_reason=absent
  [ -n "$cache_body" ] || return 1
  if [ "$cache_bypass" -ne 0 ]; then cache_miss_reason=bypassed; return 1; fi
  [ -f "$cache_meta" ] || return 1
  # A meta that survived but whose body did not is a torn entry, not a cold
  # read: `cache_prune` or a partial disk-full write left the stamp behind.
  # Recorded as `absent` it reads on the dashboard as a cold cache with diverse
  # shapes and store-integrity failures go unseen — the misdiagnosis #2207
  # exists to prevent. It is a distinct cause from `corrupt` (present but
  # unreadable) and from `absent` (nothing was ever stored).
  [ -f "$cache_body" ] || { cache_miss_reason=torn; return 1; }
  if [ ! -r "$cache_body" ]; then cache_miss_reason=corrupt; return 1; fi

  cache_fetched_at=
  IFS= read -r cache_fetched_at < "$cache_meta" 2>/dev/null || { cache_miss_reason=corrupt; return 1; }
  case "$cache_fetched_at" in
    ''|*[!0-9]*) cache_miss_reason=corrupt; return 1 ;;
  esac

  # A clock that moved backwards, or an entry stamped in the future, is not
  # something to reason about — treat it as a miss and re-fetch.
  #
  # Compared against `$cache_now` rather than this process's start: a coalesced
  # follower looks again after waiting, and measured from its start an entry the
  # leader wrote one second later would read as stamped in the future and be
  # refused — precisely the duplicate fetch the wait existed to avoid.
  if [ "$cache_fetched_at" -gt "$cache_now" ]; then cache_miss_reason=clock-skewed; return 1; fi
  if [ $((cache_now - cache_fetched_at)) -gt "$cache_ttl" ]; then cache_miss_reason=expired; return 1; fi

  cache_invalidated_at=0
  cache_marker_at "$cache_root/v1/.invalidated"
  cache_marker_at "$cache_repo_dir/.invalidated"
  [ "$cache_collection" -eq 0 ] || cache_marker_at "$cache_repo_dir/.collections-invalidated"
  cache_marker_at "$cache_entry_dir/.invalidated"

  if [ "$cache_fetched_at" -le "$cache_invalidated_at" ]; then cache_miss_reason=invalidated; return 1; fi
  cache_miss_reason=
  return 0
}

cache_write_file() {
  cache_write_target=$1
  cache_write_tmp=$1.$$.tmp

  case "$cache_write_target" in
    */*) mkdir -p "${cache_write_target%/*}" 2>/dev/null || { unset cache_write_target cache_write_tmp; return 1; } ;;
  esac

  if printf '%s\n' "$2" > "$cache_write_tmp" 2>/dev/null &&
    mv -f "$cache_write_tmp" "$cache_write_target" 2>/dev/null; then
    unset cache_write_target cache_write_tmp
    return 0
  fi

  rm -f "$cache_write_tmp" 2>/dev/null || true
  unset cache_write_target cache_write_tmp
  return 1
}

# Marked with the moment the mutation FINISHED, and entries with the moment
# their read STARTED. Both choices are load-bearing:
#
#   * A read that began before the write completed is retired even if its
#     response arrived afterwards, because its stamp predates the marker.
#     Stamping the marker at the mutation's start would leave that read — which
#     cannot contain the change — looking newer than the change, and an agent
#     would be unable to see the comment it had just posted for the whole
#     window.
#   * The error runs one way only: a read that genuinely postdates the write is
#     also retired when it began within the same second, costing one re-fetch.
#     Over-invalidation is the only acceptable direction here.
cache_invalidate_writes() {
  [ -n "$cache_root" ] || return 0
  [ "$direction" = write ] || return 0

  cache_finished_at=$(date -u +%s 2>/dev/null || printf '')
  case "$cache_finished_at" in ''|*[!0-9]*) cache_finished_at=$cache_started_at ;; esac
  case "$cache_finished_at" in ''|*[!0-9]*) return 0 ;; esac

  if [ -z "$cache_repo_dir" ]; then
    # A write whose repository could not be identified may have changed
    # anything, so nothing may be trusted. This is deliberately blunt: a rare
    # over-invalidation costs one re-fetch, while a missed one serves a stale
    # answer for the whole freshness window.
    cache_write_file "$cache_root/v1/.invalidated" "$cache_finished_at" || true
    unset cache_finished_at
    return 0
  fi

  cache_write_file "$cache_repo_dir/.collections-invalidated" "$cache_finished_at" || true

  case "$cache_write_id" in
    # A write whose subject is a SUBRESOURCE — a comment id, a review id — names
    # a number that is not an issue or pull request number, and the parent it
    # belongs to is not derivable from it. Retiring the repository for it would
    # be correct and ruinous: agents rewrite their workpad comment every few
    # minutes, so every edit would flush the whole store and the sharing this
    # exists for would never happen. The collections marker is the honest scope.
    collection|subresource) ;;
    ''|*[!0-9]*) cache_write_file "$cache_repo_dir/.invalidated" "$cache_finished_at" || true ;;
    *)
      cache_write_file "$cache_repo_dir/pr/$cache_write_id/.invalidated" "$cache_finished_at" || true
      cache_write_file "$cache_repo_dir/issue/$cache_write_id/.invalidated" "$cache_finished_at" || true
      ;;
  esac

  unset cache_finished_at
  return 0
}

cache_store() {
  [ -n "$cache_body" ] || return 0
  [ -n "$cache_stage" ] && [ -f "$cache_stage" ] || return 0
  [ "${status:-1}" -eq 0 ] || return 0

  cache_size=$(wc -c < "$cache_stage" 2>/dev/null || printf '')
  case "$cache_size" in
    ''|*[!0-9]*) unset cache_size; return 0 ;;
  esac
  if [ "$cache_size" -gt "$cache_max_bytes" ]; then unset cache_size; return 0; fi
  unset cache_size

  mkdir -p "$cache_entry_dir" 2>/dev/null || return 0

  cache_body_tmp=$cache_body.$$.tmp
  if cat "$cache_stage" > "$cache_body_tmp" 2>/dev/null && mv -f "$cache_body_tmp" "$cache_body" 2>/dev/null; then
    # The body lands first and the stamp commits the entry, so a reader that
    # finds a readable stamp always finds a complete body behind it. Line 1 of
    # the meta stays the fetched-at stamp (the only line `cache_lookup` reads);
    # line 2, when present, is the response ETag a later re-read validates
    # against (#2307 conditional reads). No other reader touches line 2.
    cache_meta_body=$cache_started_at
    if [ -n "$cache_response_etag" ]; then cache_meta_body="$cache_started_at
$cache_response_etag"; fi
    cache_write_file "$cache_meta" "$cache_meta_body" || rm -f "$cache_body" 2>/dev/null || true
    cache_record store
    unset cache_meta_body
  else
    rm -f "$cache_body_tmp" 2>/dev/null || true
  fi

  unset cache_body_tmp
  return 0
}

# Entries are never read after their window closes, so retention exists only to
# stop the store growing without bound. Backgrounded and rate-limited to once an
# hour so it never appears in the latency of a call.
cache_prune() {
  [ -n "$cache_root" ] || return 0
  [ -d "$cache_root/v1" ] || return 0
  command -v find >/dev/null 2>&1 || return 0

  cache_pruned_at=0
  if [ -f "$cache_root/v1/.pruned" ]; then
    IFS= read -r cache_pruned_at < "$cache_root/v1/.pruned" 2>/dev/null || cache_pruned_at=0
    case "$cache_pruned_at" in
      ''|*[!0-9]*) cache_pruned_at=0 ;;
    esac
  fi

  if [ $((cache_started_at - cache_pruned_at)) -lt 3600 ]; then unset cache_pruned_at; return 0; fi
  unset cache_pruned_at
  cache_write_file "$cache_root/v1/.pruned" "$cache_started_at" || return 0

  # The subshell's own descriptors are redirected, not just the `find`'s: a
  # background job keeping a copy of this script's stdout holds the pipe open,
  # and `$(gh pr view ...)` blocks on EOF — so an unredirected sweep would stall
  # the very command it was meant to be invisible to.
  (
    find "$cache_root/v1" -type f \( -name '*.body' -o -name '*.meta' \) -mmin +120 -delete || true
  ) >/dev/null 2>&1 &

  return 0
}

# Answers with the stored bytes, or refuses. `cat` is checked because the entry
# can go away between the readability test and the read, and an unchecked `cat`
# would hand the agent empty stdout with exit 0, which `out=$(gh pr view N
# --json body -q .body)` reads as "the body is empty". A refusal here falls
# through to the real `gh`, the same answer every other doubt in this file
# produces.
cache_serve() {
  if ! cat "$cache_body"; then
    # Body vanished between lookup and read — the miss is `corrupt`, not `absent`.
    cache_miss_reason=corrupt
    return 1
  fi
  cache_record "$1"
  return 0
}

# A second look, with the clock re-sampled. Between a caller's own lookup and
# the moment it is admitted to spend, another agent's identical fetch can land —
# so every point where this call is about to reach GitHub asks once more first.
# One `date` and a handful of stats against a network round trip.
cache_recheck() {
  [ -n "$cache_body" ] || return 1

  cache_now=$(date -u +%s 2>/dev/null || printf '%s' "$cache_started_at")
  case "$cache_now" in ''|*[!0-9]*) cache_now=$cache_started_at ;; esac

  cache_lookup
}

if cache_lookup && cache_serve hit; then
  exit 0
fi

[ -z "$cache_body" ] || cache_record miss "${cache_miss_reason:-absent}"

# COALESCING (#2073 U6). A hit above costs no `python3` and no network, so the
# store already removes the second and later reads of a resource. It cannot
# remove the SIMULTANEOUS ones: agents that all look before any answers all
# miss and all pay. So the miss path names the shape it is about to fetch, and
# the broker — the one place every agent on the host meets under a transaction —
# admits one fetcher per shape and tells the rest to wait, look again, and find
# the leader's answer. The claim is bounded by its own TTL and the waiter's
# patience, so a leader that dies costs one duplicate fetch, never a stall. A
# caller demanding strict freshness refuses stored answers by definition, so it
# takes no part in this.
#
# The key's members are all constrained: owner and repo pass `cache_valid_slug`
# (`[A-Za-z0-9./_-]`, no `..`), the kind is a literal, the id is digits, `list`
# or a hex digest, and the shape is a 64-character hex digest. That is what makes
# the unquoted expansion into the broker's argument list below safe; relax
# `cache_valid_slug` and this becomes argument injection.
cache_claim_key=
if [ -n "$cache_body" ] && [ -n "$cache_shape" ] && [ "$cache_bypass" -eq 0 ]; then
  cache_claim_key=$cache_owner/$cache_repo_name/$cache_kind/$cache_id/$cache_shape
fi

# How long a follower waits for the leader before deciding it is not coming and
# fetching for itself. Bounded on purpose: a wait that could outlast the call it
# replaces would turn a saving into a hang. Measured against the CLOCK, not the
# sleeps the broker advertised — each iteration also pays a `python3` start and
# a SQLite write transaction, so counting only the advertised sleep understated
# the real wait by more than 2x.
cache_claim_wait_budget_ms=${AIUR_GITHUB_STATE_CACHE_WAIT_MS:-15000}
case "$cache_claim_wait_budget_ms" in ''|*[!0-9]*) cache_claim_wait_budget_ms=15000 ;; esac
cache_claim_wait_budget=$(( (cache_claim_wait_budget_ms + 999) / 1000 ))
cache_claim_waited_ms=0
cache_claim_overtake=0
cache_served=0


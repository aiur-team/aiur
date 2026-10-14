# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
error_file=
status_file=
output_file=
api_capture=0
api_requested_include=0
stderr_streamed=0
cache_served_304=0
cache_response_etag=
cache_conditional_etag=

# A 304 "Not Modified" is detected from the response status line, never from
# gh's exit code: gh exits 1 on a 304, but a served 304 is a SUCCESS that
# answers from the cache (#2307 agent conditional reads). Reads the HTTP status
# line that `--include` puts at the top of `output_file`.
response_status_is_304() {
  [ -n "$output_file" ] && [ -f "$output_file" ] || return 1
  awk '/^HTTP\/[^[:space:]]+[[:space:]]+[0-9][0-9][0-9]/ { status = $2 } END { exit status == 304 ? 0 : 1 }' "$output_file"
}

# `gh api` is always run with `--include` so the rate-limit headers can be read,
# then the headers are stripped again unless the caller asked for them. The
# bytes this prints are what the caller sees, so they are also exactly what the
# cache must store. On a served 304 the response carried no body, so the answer
# is the cached body — which for an `--include` entry is already the correct
# include-shaped bytes (headers and body), and for a plain entry the body alone,
# exactly as a fresh cache hit serves the same entry. A 304 means "what you hold
# is current" (#2307), so serving the cached body to an `--include` caller must
# not be replaced by the bare 304 status line the response actually carried.
emit_api_output() {
  if [ "$cache_served_304" -eq 1 ] && [ -n "$cache_body" ] && [ -f "$cache_body" ]; then
    cat "$cache_body"
  elif [ "$api_requested_include" -eq 1 ]; then
    cat "$output_file"
  elif sed -n '1p' "$output_file" | grep -Eq '^HTTP/'; then
    sed '1,/^[[:space:]]*$/d' "$output_file"
  else
    cat "$output_file"
  fi
}
if [ "$resource" != none ]; then
  old_umask=$(umask)
  umask 077
  error_file=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-stderr.XXXXXX" 2>/dev/null || true)
  status_file=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-status.XXXXXX" 2>/dev/null || true)
  umask "$old_umask"
fi

# High-level budgeted commands (anything but `gh api`, which already captures
# its status through `--include`) run under `GH_DEBUG=api` so the wrapper can
# see whether the response was a free 304. `gh` prints the status line only in
# that transcript; without it every `pr view`/`issue view`/`search` 304 is
# billed as if it had cost quota (#2353). `run watch` is the one interactive
# streamer and is deliberately excluded: its stderr must stay live, and a debug
# transcript interleaved with its progress would be worse than the accounting
# gap. Every other high-level command is buffered (below) so the transcript is
# consumed for reconciliation and then stripped before the caller sees stderr.
if [ "$budget_enabled" -eq 1 ] && [ "$resource" != none ] && [ "${1:-}" != api ]; then
  case "${1:-} ${2:-}" in
    "run watch") : ;;
    *) high_level_debug=1 ;;
  esac
fi

if [ -n "$error_file" ]; then
  if [ "${1:-}" = api ]; then
    for api_arg in "$@"; do
      case "$api_arg" in
        --include|--include=true|-i) api_requested_include=1 ;;
        --paginate) : ;;
      esac
    done

    if [ "$api_paginated" -eq 0 ]; then
      old_umask=$(umask)
      umask 077
      output_file=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-stdout.XXXXXX" 2>/dev/null || true)
      umask "$old_umask"
      [ -n "$output_file" ] && api_capture=1
    fi
  fi

  # A cacheable read is captured so its exact bytes can be stored. Only the
  # shapes classified above reach this branch, and all of them are short,
  # one-shot, machine-readable reads — nothing that streams progress or prompts,
  # which is why the `tee` branch below still exists for everything else.
  if [ -n "$cache_body" ] && [ "$api_capture" -eq 0 ]; then
    old_umask=$(umask)
    umask 077
    cache_stage=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-cache.XXXXXX" 2>/dev/null || true)
    umask "$old_umask"
  fi

  if [ "$api_capture" -eq 1 ]; then
    # stdout is already being captured for header parsing, so there is no live
    # output to interleave with; buffering stderr here costs nothing.
    #
    # Conditional re-read (#2307): when the store holds a body AND a validator
    # for this resource, the re-fetch sends If-None-Match so an unchanged
    # answer comes back 304 and is reconciled free instead of billed again. The
    # validator is only ever offered while a body is held — a 304 with no body
    # would spend a request and learn nothing (the same contract as the
    # daemon's ResourceStore). gh exits 1 on a 304, which is not a failure
    # here: the 304 is detected from the status line below and the cached body
    # answers the call.
    cache_conditional_etag=
    if [ -n "$cache_body" ] && [ -f "$cache_body" ] && [ -f "$cache_meta" ]; then
      cache_conditional_etag=$(sed -n '2p' "$cache_meta" 2>/dev/null || printf '')
    fi
    if [ -n "$cache_conditional_etag" ]; then
      if [ "$api_requested_include" -eq 1 ]; then
        run_gh "$@" -H "If-None-Match: $cache_conditional_etag" > "$output_file" 2> "$error_file"
      else
        run_gh "$@" -H "If-None-Match: $cache_conditional_etag" --include > "$output_file" 2> "$error_file"
      fi
    elif [ "$api_requested_include" -eq 1 ]; then
      run_gh "$@" > "$output_file" 2> "$error_file"
    else
      run_gh "$@" --include > "$output_file" 2> "$error_file"
    fi
    status=$?

    # The response's own ETag is what a later re-read validates against. On a
    # served 304 the response carries the same validator, so capturing it here
    # also keeps the entry's validator in place. `tr` is gated because an
    # isolated `PATH` (the test harness, a hardened shell) may lack it; without
    # it a trailing CR is left on the stored validator, which only costs a
    # later 304 match, never correctness.
    if [ -n "$output_file" ] && [ -f "$output_file" ]; then
      cache_response_etag=$(sed -n -E 's/^[[:space:]]*[Ee][Tt][Aa][Gg]:[[:space:]]*(.*)$/\1/p' "$output_file" | tail -n 1)
      if command -v tr >/dev/null 2>&1; then
        cache_response_etag=$(printf '%s\n' "$cache_response_etag" | tr -d '\r')
      fi
    fi

    if response_status_is_304 && [ -n "$cache_body" ] && [ -f "$cache_body" ]; then
      cache_served_304=1
      status=0
    fi
  elif [ -n "$cache_stage" ]; then
    if [ "$high_level_debug" -eq 1 ]; then
      ( GH_DEBUG=api; export GH_DEBUG; run_gh "$@" ) > "$cache_stage" 2> "$error_file"
    else
      run_gh "$@" > "$cache_stage" 2> "$error_file"
    fi
    status=$?
    cat "$cache_stage"
  elif [ -n "$status_file" ] && command -v tee > /dev/null 2>&1 && [ "$high_level_debug" -eq 0 ]; then
    # Pass stderr through `tee` so it reaches the terminal as it is written
    # while still being captured for the rate-limit classification below.
    # Replaying a buffered copy after exit stalls `gh run watch` progress — an
    # allowlisted read — and swallows interactive prompts. `tee` ends the
    # pipeline, so the real exit status travels via `status_file`.
    { { run_gh "$@"; printf '%s\n' "$?" > "$status_file"; } 2>&1 1>&3 | tee "$error_file" >&2; } 3>&1
    stderr_streamed=1
    # An unreadable or non-numeric status means the real exit code could not be
    # confirmed. Reporting 0 there would turn a failed `gh` into an apparent
    # success for every caller, so this fails closed instead.
    status=$(sed -n '1p' "$status_file" 2>/dev/null)
    case "$status" in
      ''|*[!0-9]*) status=1 ;;
    esac
  else
    if [ "$high_level_debug" -eq 1 ]; then
      ( GH_DEBUG=api; export GH_DEBUG; run_gh "$@" ) 2> "$error_file"
    else
      run_gh "$@" 2> "$error_file"
    fi
    status=$?
  fi

  if [ "$api_capture" -eq 1 ]; then
    emit_api_output

    # The cache copy is produced by a SECOND pass rather than by redirecting the
    # first. The agent's stdout must not depend on the cache being writable.
    # On a served 304 the response carried no body, so nothing is re-stored —
    # the existing body stays and the entry's stamp is refreshed below.
    if [ "$cache_served_304" -eq 0 ] && [ -n "$cache_body" ] && [ "$status" -eq 0 ]; then
      old_umask=$(umask)
      umask 077
      cache_stage=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-cache.XXXXXX" 2>/dev/null || true)
      umask "$old_umask"
      if [ -n "$cache_stage" ]; then emit_api_output > "$cache_stage" 2>/dev/null || cache_stage=; fi
    fi
  fi

  # High-level 304s reconcile here, before the transcript would otherwise leak:
  # the status is read for reconciliation and then the debug is stripped so the
  # replay below is exactly the stderr the caller would have seen without it.
  if [ "$high_level_debug" -eq 1 ]; then
    budget_reconcile_debug
  fi

  if [ "$stderr_streamed" -eq 0 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      # gh prints `gh: HTTP 304` on stderr for a served 304 — noise that would
      # read as a failure. A 304 is a success answered from the cache.
      if [ "$cache_served_304" -eq 1 ] && printf '%s\n' "$line" | grep -Eiq '^gh: HTTP 304'; then
        continue
      fi
      printf '%s\n' "$line" >&2
    done < "$error_file"
  fi
else
  run_gh "$@"
  status=$?
fi

probe_rate_limit() {
  original_resource=$resource
  original_admission_resource=$admission_resource
  original_family=$endpoint_family
  # The probe is a different request against a different resource. Claiming the
  # original read's shape for it would make every follower wait on an answer this
  # call is never going to write — and, worse, admission is re-entered here AFTER
  # the real `gh` has already failed, so a cached body found during the probe
  # would be printed onto the stdout of a call about to exit non-zero
  # (`$(gh ... --json ...)` would read that as success). Both the claim and the
  # ability to serve are withdrawn for the duration.
  original_claim_key=$cache_claim_key
  original_cache_body=$cache_body
  cache_claim_key=
  cache_body=
  immediate_cooldown=$(secondary_delay_ms "$error_file" "$output_file")
  budget_hold token "$immediate_cooldown"
  budget_release
  resource=core
  admission_resource=core
  endpoint_family=rate_limit
  budget_ignore_token_cooldown=1
  if budget_acquire; then
    budget_start_renewal
    rate_limit_observation=$(run_gh api rate_limit --template '{{.resources.core.remaining}} {{.resources.core.reset}} {{.resources.graphql.remaining}} {{.resources.graphql.reset}}' 2>/dev/null || true)
  else
    rate_limit_observation=
  fi
  budget_ignore_token_cooldown=0
  budget_release
  resource=$original_resource
  admission_resource=$original_admission_resource
  endpoint_family=$original_family
  cache_claim_key=$original_claim_key
  cache_body=$original_cache_body
  unset original_resource original_admission_resource original_family original_claim_key original_cache_body \
    immediate_cooldown
}

rate_limited_response() {
  grep -Eiq 'rate.?limit|rate_limit' "$error_file" && return 0
  [ -n "$output_file" ] && grep -Eiq 'rate.?limit|rate_limit' "$output_file" && return 0
  [ -n "$output_file" ] && grep -Eq '^HTTP/[0-9.]+[[:space:]]+(403|429)' "$output_file" && grep -Eiq '^[Rr]etry-[Aa]fter:' "$output_file"
}

record_successful_budget_hold() {
  [ "$status" -eq 0 ] || return 0
  [ -n "$output_file" ] && [ -f "$output_file" ] || return 0

  response_remaining=$(sed -n -E 's/^[[:space:]]*[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Mm][Aa][Ii][Nn][Ii][Nn][Gg]:[[:space:]]*([0-9]+).*/\1/p' "$output_file" | tail -n 1)
  response_reset=$(sed -n -E 's/^[[:space:]]*[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Ss][Ee][Tt]:[[:space:]]*([0-9]+).*/\1/p' "$output_file" | tail -n 1)

  case "$response_remaining:$response_reset" in
    0:[0-9]*)
      response_delay=$(( (response_reset - $(date -u +%s)) * 1000 ))
      if [ "$response_delay" -gt 0 ]; then
        publish_hold "$resource-hold" "$response_reset"
        budget_hold resource "$response_delay" "$resource"
      fi
      ;;
  esac

  unset response_remaining response_reset response_delay
}

record_successful_budget_hold
budget_reconcile_response

# A mutation invalidates before its response is stored, so an agent that edits a
# pull request and immediately reads it back can never be answered from the copy
# it just superseded. Invalidation runs whatever the exit status was: a write
# that failed late may still have landed.
if [ -n "$cache_root" ]; then
  cache_old_umask=$(umask)
  umask 077
fi
cache_invalidate_writes
cache_store
# A served 304 confirmed the cached body is current: refresh the fetched-at
# stamp so the entry stays warm (the re-validated answer is as fresh as a 200)
# while keeping the stored body — the 304 carried no bytes to store.
if [ "$cache_served_304" -eq 1 ] && [ -n "$cache_meta" ]; then
  cache_meta_body=$cache_started_at
  if [ -n "$cache_conditional_etag" ]; then cache_meta_body="$cache_started_at
$cache_conditional_etag"; fi
  cache_write_file "$cache_meta" "$cache_meta_body" || true
  unset cache_meta_body
fi
cache_prune
if [ -n "$cache_root" ]; then umask "$cache_old_umask"; fi
if [ -n "$cache_stage" ]; then rm -f "$cache_stage" 2>/dev/null || true; fi

if [ "$status" -ne 0 ] && [ -n "$error_file" ] && rate_limited_response && { [ -n "$agent_quota_dir" ] || [ "$budget_enabled" -eq 1 ]; }; then
  probe_rate_limit
  observation=$rate_limit_observation
  unset rate_limit_observation
  set -- $observation
  exhausted=0

  if [ "$#" -eq 4 ]; then
    core_remaining=$1
    core_reset=$2
    graphql_remaining=$3
    graphql_reset=$4

    case "$core_remaining:$core_reset" in
      0:[0-9]*)
        publish_hold "core-hold" "$core_reset"
        budget_delay=$(( (core_reset - $(date -u +%s)) * 1000 ))
        if [ "$budget_delay" -gt 0 ]; then budget_hold resource "$budget_delay" core; fi
        exhausted=1
        ;;
    esac
    case "$graphql_remaining:$graphql_reset" in
      0:[0-9]*)
        publish_hold "graphql-hold" "$graphql_reset"
        budget_delay=$(( (graphql_reset - $(date -u +%s)) * 1000 ))
        if [ "$budget_delay" -gt 0 ]; then budget_hold resource "$budget_delay" graphql; fi
        exhausted=1
        ;;
    esac

    if [ "$exhausted" -eq 1 ]; then
      printf '%s\n' 'aiur: GitHub quota exhausted; exact reset backoff recorded' >&2
    fi
  fi

  # A rate-limit refusal while both primary windows still read healthy is a
  # secondary (abuse) limit. Nothing in the primary windows records it, so
  # without its own backoff the next call retries straight into another
  # rejection. Honour Retry-After when gh exposes it, with GitHub's 60-second
  # guidance as the fallback.
  if [ "$exhausted" -eq 0 ]; then
    secondary_delay=$(secondary_delay_ms "$error_file" "$output_file")
    secondary_wait_seconds=$(( (secondary_delay + 999) / 1000 ))
    secondary_until=$(( $(date -u +%s) + secondary_wait_seconds ))

    case "$resource" in
      core|graphql) publish_hold "$resource-secondary-hold" "$secondary_until" ;;
      *)
        publish_hold "core-secondary-hold" "$secondary_until"
        publish_hold "graphql-secondary-hold" "$secondary_until"
        ;;
    esac

    printf 'aiur: GitHub secondary rate limit; backing off %ss before the next call\n' "$secondary_wait_seconds" >&2
    budget_hold token "$secondary_delay"
  fi
fi

budget_release
if [ -n "$error_file" ]; then rm -f "$error_file" 2>/dev/null || true; fi
if [ -n "$status_file" ]; then rm -f "$status_file" 2>/dev/null || true; fi
if [ -n "$output_file" ]; then rm -f "$output_file" 2>/dev/null || true; fi
exit "$status"

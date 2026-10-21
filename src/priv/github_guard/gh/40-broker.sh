# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
budget_command() {
  if [ -n "$budget_identity_key" ]; then
    python3 -I "$budget_broker" "$@" --db "$budget_db" --token-key "$budget_key" --identity-key "$budget_identity_key"
  else
    python3 -I "$budget_broker" "$@" --db "$budget_db" --token-key "$budget_key"
  fi
}

budget_sleep_ms() {
  budget_delay=$1
  case "$budget_delay" in ''|0|*[!0-9]*) return 1 ;; esac
  budget_seconds=$(awk "BEGIN { printf \"%.3f\", $budget_delay / 1000 }")
  interruptible_sleep "$budget_seconds"
}

# A foreground sleep can defer a shell's TERM trap until the child exits. Keep
# its pid so the trap can stop an in-flight wait and `wait` itself is
# interruptible by a trapped signal.
interruptible_sleep() {
  sleep "$1" >/dev/null 2>&1 &
  interruptible_sleep_pid=$!
  wait "$interruptible_sleep_pid"
  interruptible_sleep_status=$?
  interruptible_sleep_pid=
  return "$interruptible_sleep_status"
}

stop_interruptible_sleep() {
  if [ -n "${interruptible_sleep_pid:-}" ]; then
    kill "$interruptible_sleep_pid" 2>/dev/null || true
    wait "$interruptible_sleep_pid" 2>/dev/null || true
    interruptible_sleep_pid=
  fi
}

# The broker's captured stdout+stderr, folded into one bounded line fit for an
# error message. A traceback is several lines and a SQLite message can be long,
# and this text is read out of a CI log and an ExUnit failure, so it is squeezed
# to single spaces and truncated. Empty output is itself a diagnosis — a
# subprocess that died on a signal says nothing — so it is named rather than
# left as an empty parenthesis.
budget_diagnostic_line() {
  budget_diagnostic=$(printf '%s\n' "$1" | tr '\n\t' '  ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-400)
  if [ -n "$budget_diagnostic" ]; then
    printf '%s' "$budget_diagnostic"
  else
    printf '%s' 'broker exited non-zero without output'
  fi
  unset budget_diagnostic
}

# Whether the broker's own diagnostic says it could not reach its storage. Only
# then is the ownership/permissions/writableRoots recovery text the right advice:
# it IS the fix for a budget root the sandbox never granted, and it is noise for
# a broker that opened the ledger fine and aborted on something else. Matching on
# what the broker actually reported is what keeps this from becoming the blanket
# misdiagnosis it replaced (#2499).
budget_storage_failure() {
  case "$1" in
    *"unable to open database file"*|*"readonly database"*|*"read-only database"*) return 0 ;;
    *"Permission denied"*|*"permission denied"*|*"Errno 13"*|*"disk I/O error"*) return 0 ;;
  esac
  return 1
}

valid_budget_lease() {
  case "$1" in ''|*[!0-9abcdef]*) return 1 ;; esac
  [ "${#1}" -eq 32 ]
}

valid_budget_hold_reset() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac

  python3 -I - "$1" <<'PY'
import sys
import time

# Mirrors the Elixir-side bounded window in `GithubBudgetPause.parse/3`: a
# reset no more than 24h in the future or 5 minutes in the past is a live
# hold; anything older in the past is a stale or forged value and must not be
# accepted as a typed hold (which would clamp to a zero delay and re-pause
# immediately).
reset_at_ms = int(sys.argv[1])
now_ms = time.time_ns() // 1_000_000
sys.exit(0 if now_ms - 300_000 <= reset_at_ms <= now_ms + 86_400_000 else 1)
PY
}

budget_acquire() {
  [ "$budget_enabled" -eq 1 ] || return 0

  # Free endpoints (the shared EndpointPolicy table marks only `rate_limit`
  # non-billable) are still admitted and leased for ordering, but their
  # admission row must be recorded non-billable so the ledger never reports
  # them as spend — the same `--billable 0` the daemon's Budget path passes
  # (#2353). The broker defaults to `1`, so omitting this would bill every
  # `/rate_limit` probe as core spend.
  budget_billable_flag=
  [ "$endpoint_family" = rate_limit ] && budget_billable_flag="--billable 0"

  while :; do
    # Whatever this loop last waited for — a hold, a full lease table, another
    # agent's identical fetch — the answer may have arrived meanwhile. Looking
    # again is a stat and a `read`, so it is cheaper than any of the reasons the
    # loop is here.
    if [ "$cache_claim_waited_ms" -gt 0 ] && cache_recheck && cache_serve coalesced; then
      cache_served=1
      return 66
    fi

    budget_ignore_flag=
    [ "$budget_ignore_token_cooldown" -eq 1 ] && budget_ignore_flag=--ignore-token-cooldown
    budget_cache_flags=
    if [ -n "$cache_claim_key" ]; then
      budget_cache_flags="--cache-key $cache_claim_key --cache-claim-ttl-ms $budget_lease_ttl_ms"
      [ "$cache_claim_overtake" -eq 1 ] && budget_cache_flags="$budget_cache_flags --cache-ignore-claim"
    fi
    if ! budget_result=$(budget_command acquire --resource "$admission_resource" --consumer-key "$budget_consumer_key" --consumer-label "$budget_consumer_label" --endpoint-family "$endpoint_family" \
      $budget_ignore_flag $budget_cache_flags $budget_billable_flag \
      --max-inflight "${AIUR_GITHUB_MAX_INFLIGHT:-4}" \
      --max-inflight-per-endpoint "${AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT:-2}" \
      --requests-per-minute "${AIUR_GITHUB_REQUESTS_PER_MINUTE:-300}" \
      --stagger-ms "${AIUR_GITHUB_STAGGER_MS:-75}" --lease-ttl-ms "$budget_lease_ttl_ms" \
      --core-limit "${AIUR_GITHUB_CORE_LIMIT_PER_HOUR:-0}" \
      --graphql-limit "${AIUR_GITHUB_GRAPHQL_LIMIT_PER_HOUR:-0}" \
      --search-limit "${AIUR_GITHUB_SEARCH_LIMIT_PER_HOUR:-0}" 2>&1); then
      # A broker that predates the ledger schema (the trigger refuses its
      # lease-less admission INSERT) or the ledger's version stamp cannot be
      # admitted to this ledger. That is exactly the stale-broker population
      # #2307 exists for, and failing closed here would turn a working-but-
      # over-billing workspace into a hard `gh` outage with zero alerts: acquire
      # aborts before a lease exists, so the reconcile marker machinery would
      # never run. Fail OPEN instead — the request proceeds uncoordinated, just
      # as the stale broker behaved before the ledger was versioned — and write
      # the marker once so the daemon raises a fleet alert.
      if budget_stale_abort "$budget_result"; then
        budget_mark_stale_broker acquire
        return 0
      fi
      # The broker told us why it failed; say that instead of guessing. This
      # message used to print only `$budget_recovery`, which names ownership,
      # permissions and `writableRoots` as the cause. For a broker subprocess
      # that aborted on its own — a SQLite error, a Python traceback — that is a
      # confident misdiagnosis, and it sent readers to repair a directory the
      # caller had just created successfully (#2499). The captured output is the
      # evidence; the root is a locator, not a diagnosis. The recovery text is
      # kept for the one case it actually diagnoses — a broker that could not
      # reach its storage — so a genuinely ungranted budget root still tells the
      # operator how to repair it.
      budget_failure=$(budget_diagnostic_line "$budget_result")
      if budget_storage_failure "$budget_failure"; then
        printf 'aiur: GitHub budget broker unavailable (%s; %s); refusing uncoordinated request\n' \
          "$budget_failure" "$budget_recovery" >&2
      else
        printf 'aiur: GitHub budget broker unavailable (%s; budget root %s); refusing uncoordinated request\n' \
          "$budget_failure" "$budget_root" >&2
      fi
      unset budget_failure
      return 75
    fi
    unset budget_ignore_flag budget_cache_flags

    # The broker's response is the last non-empty line of its output. Stderr is
    # merged into $budget_result above (2>&1) so a stale-broker abort's trigger
    # or stamp message reaches budget_stale_abort, but a HEALTHY broker's stderr
    # — a Python DeprecationWarning, a wrapper notice, a locale complaint —
    # must not corrupt the protocol parse. The response is single-line, so take
    # the last non-empty line and match on that, not on the merged stream
    # (#2307 review: the 2>&1 change had re-opened an outage on healthy brokers
    # whose prefix-matched grant was buried under stderr noise).
    budget_result=$(printf '%s\n' "$budget_result" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' | tail -n 1)

    case "$budget_result" in
      "granted "*)
        budget_lease=${budget_result#granted }
        if valid_budget_lease "$budget_lease"; then
          # Admitted, and therefore about to spend. A grant is proof this
          # workspace's broker is current for the ledger, so any stale-broker
          # marker left by an earlier structural failure is cleared here as well
          # as by the reconcile path — a refreshed workspace that never happens
          # to see a 304 must not keep alerting (#2307 review).
          budget_clear_stale_broker acquire
          # The window between this
          # call's own lookup and this grant is exactly where a simultaneous
          # reader's answer lands, and it is not covered by the claim: a caller
          # arriving after the leader released has no claim to wait behind and
          # would fetch a resource that is already in the store.
          if [ -n "$cache_claim_key" ] && cache_recheck && cache_serve coalesced; then
            cache_served=1
            budget_release
            return 66
          fi

          return 0
        fi
        printf '%s\n' 'aiur: GitHub budget broker returned an invalid admission response' >&2
        return 75
        ;;
      "hold shared "*)
        budget_hold=${budget_result#hold shared }
        budget_hold_resource=${budget_hold%% *}
        budget_hold_reset_at_ms=${budget_hold#* }
        case "$budget_hold_resource:$budget_hold_reset_at_ms" in
          core:*|graphql:*)
            if valid_budget_hold_reset "$budget_hold_reset_at_ms"; then
              printf 'aiur: github budget hold resource=%s reset_at_ms=%s\n' \
                "$budget_hold_resource" "$budget_hold_reset_at_ms" >&2
              return 75
            fi
            ;;
        esac
        printf '%s\n' 'aiur: GitHub budget broker returned an invalid shared hold response' >&2
        return 75
        ;;
      "wait "*)
        budget_wait_ms=${budget_result#wait }
        # An actor-ceiling hold is `wait actor <ms>`; the `actor` token is the
        # Elixir side's cue for the hold reason and is not part of the delay.
        budget_wait_ms=${budget_wait_ms#actor }
        if ! budget_sleep_ms "$budget_wait_ms"; then
          printf '%s\n' 'aiur: GitHub budget broker returned an invalid or unusable wait response' >&2
          return 75
        fi
        case "$budget_wait_ms" in
          ''|*[!0-9]*) ;;
          *) cache_claim_waited_ms=$((cache_claim_waited_ms + budget_wait_ms)) ;;
        esac
        # Patience spent. The leader may have died between claiming the resource
        # and answering for it, and a follower that waits forever on a dead
        # leader has been made worse off by the optimisation. Overtake the claim
        # and fetch; the cost is the one call this was trying to save.
        if [ -n "$cache_claim_key" ] && [ "$cache_claim_overtake" -eq 0 ]; then
          cache_waited=$(date -u +%s 2>/dev/null || printf '')
          case "$cache_waited" in
            ''|*[!0-9]*) ;;
            *)
              if [ $((cache_waited - cache_started_at)) -ge "$cache_claim_wait_budget" ]; then
                cache_claim_overtake=1
              fi
              ;;
          esac
          unset cache_waited
        fi
        unset budget_wait_ms
        ;;
      *)
        printf '%s\n' 'aiur: GitHub budget broker returned an invalid admission response' >&2
        return 75
        ;;
    esac
  done
}

budget_release() {
  budget_stop_renewal
  [ -n "$budget_lease" ] || return 0
  budget_command release --lease-id "$budget_lease" >/dev/null 2>&1 || true
  budget_lease=
}

budget_stop_renewal() {
  if [ -n "$budget_renewal_pid" ]; then
    kill "$budget_renewal_pid" 2>/dev/null || true
    budget_renewal_pid=
  fi
}

# A stale-broker acquire abort: the ledger's schema trigger refused this
# broker's lease-less admission INSERT, or the version stamp refused the write.
# Both strings are this project's own (the trigger and `_ensure_writable`), so
# this is not coupled to argparse or Python wording. Every other acquire failure
# stays fail-closed exactly as before.
budget_stale_abort() {
  case "$1" in
    *"refusing admission without a lease_id"*|*"refusing to write: ledger is stamped"*)
      return 0
      ;;
  esac
  return 1
}

# The marker write and the one-time stderr are the same event: the first
# structural stale-broker failure in a period surfaces once, and every later
# failure in that period (while the marker still stands) stays quiet so a fleet
# of 304s does not become per-request noise (#2307). The daemon's quota reader
# turns the marker into one fleet alert per workspace and rearms it when the
# marker disappears (a refreshed broker self-heals). Line 1 is the consumer
# label the daemon reads; line 2 records WHY the marker was written so the
# guard can decide which recovery signal may clear it (#2307 review).
budget_mark_stale_broker() {
  budget_stale_reason=$1
  if [ -n "$agent_quota_dir" ] && [ ! -f "$agent_quota_dir/broker-reconcile-stale" ]; then
    printf '%s\n%s\n' "$budget_consumer_label" "$budget_stale_reason" > "$agent_quota_dir/broker-reconcile-stale" 2>/dev/null || true
    printf '%s\n' 'aiur: GitHub budget broker is stale for this ledger (missing reconcile subcommand, or predates the ledger schema/version stamp); budget accounting for this workspace is disabled until the current broker is installed' >&2
  fi
  unset budget_stale_reason
}

# Which recovery signal may clear the marker depends on why it was written.
#   acquire   marker: the broker could not even be admitted to the ledger. The
#             first successful grant is proof the workspace now runs a broker
#             the daemon's release accepts, so it clears the marker even if
#             the workspace never happens to see a 304 (#2307 review).
#   reconcile marker: the broker IS admitted but cannot reconcile 304s. A later
#             grant does not prove reconcile works, so clearing on every grant
#             would re-alert on the next 304 — exactly the per-request noise
#             #2307 forbids. Only a successful reconcile clears it.
#   unknown  (a marker written before this rework, single line): conservative —
#             cleared only by a successful reconcile, same as before.
budget_clear_stale_broker() {
  budget_stale_signal=$1
  [ -n "$agent_quota_dir" ] && [ -f "$agent_quota_dir/broker-reconcile-stale" ] || { unset budget_stale_signal; return 0; }
  budget_marker_reason=$(sed -n '2p' "$agent_quota_dir/broker-reconcile-stale" 2>/dev/null || printf '')
  case "$budget_stale_signal:$budget_marker_reason" in
    reconcile:*|acquire:acquire)
      rm -f "$agent_quota_dir/broker-reconcile-stale" 2>/dev/null || true
      ;;
  esac
  unset budget_stale_signal budget_marker_reason
}

# A reconcile failure is structural — broker predates the `reconcile`
# subcommand, is older than the ledger's version stamp, cannot write to the
# ledger, or cannot run at all — unless it is a transient SQLite lock that can
# succeed on the next attempt. Distinguish by content, not by exit code: every
# structural case must be surfaced once rather than silently swallowed on every
# 304, and the argparse "invalid choice" wording is deliberately not matched
# (it is not a stability contract across Python versions; the trigger and stamp
# messages above are this project's own).
budget_reconcile_transient() {
  # $1 is the broker's merged output, $2 its exit status. A SLOW broker is not a
  # STALE one, and only staleness may raise the fleet alert: a `reconcile`-reason
  # marker is cleared by nothing but a later successful reconcile, so misreading
  # one transient fault as structural latches a permanent alert on a healthy
  # workspace. Death by signal (128+N — an OOM kill, a supervisor SIGKILL, a
  # SIGTERM at shutdown) and a non-zero exit with no output at all are both the
  # shape of an interrupted broker, not one that predates the ledger schema.
  # #2457 shows those faults are live: 28 broker timeouts in ten minutes after a
  # single daemon restart. Every structural failure still prints something —
  # argparse usage, the trigger/stamp refusal, `python3: not found`, a traceback
  # — so it stays on the loud path.
  case "$2" in
    12[89]|1[3-9][0-9]|2[0-9][0-9])
      return 0
      ;;
  esac
  [ -n "$1" ] || return 0
  case "$1" in
    *"database is locked"*|*"database table is locked"*)
      return 0
      ;;
  esac
  return 1
}

budget_reconcile_response() {
  [ "$budget_enabled" -eq 1 ] || return 0
  [ -n "$budget_lease" ] || return 0
  [ -n "$output_file" ] && [ -f "$output_file" ] || return 0

  if awk '/^HTTP\/[^[:space:]]+[[:space:]]+[0-9][0-9][0-9]/ { status = $2 } END { exit status == 304 ? 0 : 1 }' "$output_file"; then
    if budget_reconcile_output=$(budget_command reconcile --lease-id "$budget_lease" --status 304 2>&1); then
      # Reconcile succeeded: a refreshed broker has recovered, so clear any
      # stale-broker marker left by an earlier structural failure.
      budget_clear_stale_broker reconcile
    else
      budget_reconcile_status=$?

      if ! budget_reconcile_transient "$budget_reconcile_output" "$budget_reconcile_status"; then
        budget_mark_stale_broker reconcile
      fi
    fi
  fi
  unset budget_reconcile_output budget_reconcile_status
}

# 304 reconciliation for high-level commands. `gh` only exposes the HTTP status
# under `GH_DEBUG=api`, so the guarded run above captured it in `$error_file` as
# `< HTTP/... <status>` lines. A high-level command can issue several HTTP
# requests under one lease (`gh pr view` resolves the repo through git
# subprocesses and then makes one or more API requests), so the reconcile fires
# only when EVERY observed status is 304 — a single 304 among 200s must not
# mark the whole lease free, which under-reported spend whenever a 200 preceded
# a 304 (#2353 review). Then the whole debug transcript is stripped so every
# later consumer (rate-limit classification, stderr replay) sees only the real
# stderr. A command that produced no debug (budget disabled, no request, a
# caller that already set its own debug) is a no-op here.
budget_reconcile_debug() {
  [ "$budget_enabled" -eq 1 ] || return 0
  [ -n "$budget_lease" ] || return 0
  [ -n "$error_file" ] && [ -f "$error_file" ] || return 0

  debug_statuses=$(sed -n -E 's/^< HTTP\/[^[:space:]]+[[:space:]]+([0-9]{3}).*/\1/p' "$error_file")
  all_304=1
  case "$debug_statuses" in
    '') all_304=0 ;;
    *)
      for debug_status in $debug_statuses; do
        case "$debug_status" in
          304) ;;
          *) all_304=0; break ;;
        esac
      done
      ;;
  esac
  if [ "$all_304" -eq 1 ]; then
    budget_command reconcile --lease-id "$budget_lease" --status 304 >/dev/null 2>&1 || true
  fi
  unset all_304 debug_statuses debug_status

  strip_gh_debug "$error_file"
  return 0
}

# Drops `GH_DEBUG=api`'s transcript from a stderr capture, keeping only what
# gh printed outside it (pre-request warnings and post-request errors). The
# transcript is contiguous: every debug line between the request's start and
# its `Request took` marker — request headers, request body, response headers,
# response body — is removed, and the `[git ...]` subprocess lines `gh` prints
# BEFORE the first request marker are dropped too (they are part of the debug
# transcript, not caller-facing stderr), so the caller's stderr and the error
# classifiers see exactly what they saw before high-level debug was enabled.
strip_gh_debug() {
  [ -f "$1" ] || return 0
  strip_tmp="$1.dbg.$$"
  if awk '
    /^\* Request at / { in_debug = 1; next }
    in_debug && /^\* Request took / { in_debug = 0; next }
    !in_debug && /^\[git / { next }
    !in_debug { print }
  ' "$1" > "$strip_tmp" 2>/dev/null; then
    mv -f "$strip_tmp" "$1" 2>/dev/null || rm -f "$strip_tmp" 2>/dev/null || true
  else
    rm -f "$strip_tmp" 2>/dev/null || true
  fi
  unset strip_tmp
  return 0
}

budget_start_renewal() {
  [ -n "$budget_lease" ] || return 0
  budget_renew_interval=$((budget_lease_ttl_ms / 3 / 1000))
  [ "$budget_renew_interval" -gt 0 ] || budget_renew_interval=1

  (
    while sleep "$budget_renew_interval"; do
      budget_command renew --lease-id "$budget_lease" --lease-ttl-ms "$budget_lease_ttl_ms" >/dev/null 2>&1 || exit 0
    done
  ) >/dev/null 2>&1 &
  budget_renewal_pid=$!
  unset budget_renew_interval
}

budget_hold() {
  budget_scope=$1
  budget_delay=$2
  budget_resource=${3:-$resource}
  [ "$budget_enabled" -eq 1 ] || return 0
  budget_command hold --scope "$budget_scope" --resource "$budget_resource" --delay-ms "$budget_delay" >/dev/null 2>&1 || true
}

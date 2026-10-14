# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
dispatch_disposition() {
  label=$1
  case "$label" in
    "$dispatch_prefix:todo"|"$dispatch_prefix:queued"|human:todo|needs-triage|build-order|epic) return 0 ;;
    *) return 1 ;;
  esac
}

# #1793: a ticket created without a lifecycle label is undispatchable AND
# invisible — no agent can claim it and it appears in no state-scoped view, so
# it reads to the operator as "no work left" (29 accumulated in one run). The
# skills tell every filing path to set the disposition in the same request;
# this refuses the call that does not, because an unlabelled issue cannot be
# un-filed. Deliberately non-runnable hierarchy (Build Order roots, epics) and
# parked work still pass by naming their own disposition.
command_name=
subcommand_name=
# The third positional word, where `gh pr view 2073` and its siblings put the
# resource number. The shared-state cache reads the identity from exactly this
# position and nowhere else, so a rarer spelling such as
# `gh pr view --json body 2073` resolves to no identity and is simply not
# cached. Guessing a position instead would risk keying a response under the
# wrong number, and a wrong cached shape is worse than a cache miss.
positional_three=
positional_count=0
skip_root_value=0
for arg in "$@"; do
  if [ "$skip_root_value" -eq 1 ]; then
    skip_root_value=0
    continue
  fi
  case "$arg" in
    -R|--repo|--hostname) skip_root_value=1; continue ;;
    -R?*|--repo=*|--hostname=*) continue ;;
  esac
  positional_count=$((positional_count + 1))
  case "$positional_count" in
    1) command_name=$arg ;;
    2) subcommand_name=$arg ;;
    *) positional_three=$arg; break ;;
  esac
done
unset positional_count
command_key="$command_name $subcommand_name"

# Single-account provenance marker (#2501).
#
# When agents and the human operator share one GitHub login, the author of a
# comment no longer says who wrote it, so the daemon reads authorship from a
# marker in the body instead. This is the only place that marker can be applied
# to an agent's comment: the body is composed inside the agent process and
# reaches GitHub through `gh` without ever passing through the daemon.
#
# `AIUR_AGENT_COMMENT_MARKER` is exported only on a single-account install, so
# an unset variable — a separate-account install, an older workspace, a `gh`
# invoked outside an agent environment — leaves argv untouched byte for byte.
#
# The inline `--body`/`-b`/`--body=` forms are rewritten in argv. The
# `--body-file`/`--body-file=`/`-F` forms are stamped by copying the agent's
# file to a marked temp copy and passing that path on — the agent's own file is
# never edited, because it may be read again after the call. Stdin (`-F -`) is
# the one form that genuinely cannot be rewritten without buffering an unbounded
# stream, so it stays unmarked. An unstamped comment is read as human by
# `Aiur.Events.Publisher`, so the cost of skipping stdin is a redundant agent
# wake, never a swallowed instruction.
marker_tmp_files=
if [ -n "${AIUR_AGENT_COMMENT_MARKER:-}" ]; then
  case "$command_key" in
    "issue comment"|"pr comment"|"pr review")
      # Rotate argv exactly $# times: shift each argument off the front and
      # append it (rewritten or not) to the back, leaving "$@" in its original
      # order with the body value replaced in place.
      marker_count=$#
      marker_index=0
      marker_prior=
      while [ "$marker_index" -lt "$marker_count" ]; do
        arg=$1
        shift
        marker_stamp=0
        marker_stamp_file=0
        case "$marker_prior" in
          --body|-b) marker_stamp=1 ;;
          --body-file|-F) marker_stamp_file=1 ;;
        esac
        # Quoted so the body-file policy scan (which flags any line starting
        # with a bare `--body=`) reads this as the pattern match it is rather
        # than as a `gh` invocation passing a body inline. Same match in sh.
        case "$arg" in
          "--body="*) marker_stamp=1 ;;
          "--body-file="*) marker_stamp_file=1 ;;
        esac
        # Recorded before any rewrite, so the next iteration compares against
        # the flag the caller actually passed.
        marker_prior=$arg
        if [ "$marker_stamp" -eq 1 ]; then
          # Idempotent: a body that already carries the marker is passed through
          # untouched, so a re-run or an agent that stamped its own body does not
          # accumulate copies.
          case "$arg" in
            *"$AIUR_AGENT_COMMENT_MARKER"*) ;;
            *) arg="$arg

$AIUR_AGENT_COMMENT_MARKER" ;;
          esac
        fi
        # `--body-file` is the spelling Aiur's own skills tell agents to use
        # (the inline-body policy in `Aiur.GitHubBodyFilePolicyTest` requires
        # it), so leaving it unstamped would mean the common agent comment is
        # never marked and every agent wakes on its own reply. The file is
        # copied — never edited in place — because it belongs to the agent and
        # may be read again after the call.
        if [ "$marker_stamp_file" -eq 1 ]; then
          marker_src=$arg
          case "$arg" in
            "--body-file="*) marker_src=${arg#--body-file=} ;;
          esac
          # `-` is stdin, which cannot be rewritten without buffering an
          # unbounded stream; it stays unstamped and reads as human.
          if [ "$marker_src" != "-" ] && [ -f "$marker_src" ] &&
             ! grep -qF "$AIUR_AGENT_COMMENT_MARKER" "$marker_src" 2>/dev/null; then
            marker_tmp=${TMPDIR:-/tmp}/aiur-marked-body.$$.$marker_index
            if cat "$marker_src" > "$marker_tmp" 2>/dev/null &&
               printf '\n\n%s\n' "$AIUR_AGENT_COMMENT_MARKER" >> "$marker_tmp" 2>/dev/null; then
              marker_tmp_files="$marker_tmp_files $marker_tmp"
              case "$arg" in
                "--body-file="*) arg="--body-file=$marker_tmp" ;;
                *) arg=$marker_tmp ;;
              esac
            else
              # A copy that did not complete must not be passed to `gh`: a
              # truncated body is worse than an unstamped one.
              rm -f "$marker_tmp" 2>/dev/null || true
            fi
          fi
          unset marker_src marker_tmp
        fi
        set -- "$@" "$arg"
        marker_index=$((marker_index + 1))
      done
      unset marker_count marker_index marker_prior marker_stamp marker_stamp_file
      ;;
  esac
fi

# Marked copies of an agent's `--body-file` (#2501) live only for the duration
# of the call that sends them. The trap is armed here, immediately after the
# copies can first exist, rather than alongside the budget traps far below:
# every `exit` in between (the agent refusals, the budget-unavailable refusal,
# the validate-only and cache-hit successes) would otherwise leak one file per
# call into TMPDIR. `rm -f` on an unset/empty list is a no-op, so this is
# harmless when the marker block did not run at all — separate-account mode, a
# non-comment command, or a `-` stdin invocation where no copy is made.
marker_cleanup() {
  [ -n "${marker_tmp_files:-}" ] || return 0
  rm -f $marker_tmp_files 2>/dev/null || true
  marker_tmp_files=
}

# `budget_release` is not defined yet at this point in the script, so these
# traps clean up the marker only. They are replaced below — once the budget
# helpers exist — by traps that do both.
trap 'marker_cleanup; exit 143' HUP INT TERM
trap 'marker_cleanup' 0

if [ "$command_key" = "issue create" ]; then
  disposition=0
  prior=
  for arg in "$@"; do
    label_value=
    case "$arg" in
      --label=*) label_value=${arg#--label=} ;;
      -l?*) label_value=${arg#-l} ;;
      *)
        case "$prior" in
          --label|-l) label_value=$arg ;;
        esac
        ;;
    esac
    prior=$arg
    [ -n "$label_value" ] || continue
    # `gh` accepts repeated flags and comma-separated lists in one flag.
    old_ifs=$IFS
    IFS=,
    for label in $label_value; do
      if dispatch_disposition "$label"; then disposition=1; fi
    done
    IFS=$old_ifs
  done

  if [ "$disposition" -eq 0 ]; then
    printf '%s\n' 'aiur: refusing `gh issue create` with no dispatch disposition (#1793).' >&2
    printf '%s\n' 'aiur: an unlabelled ticket is undispatchable and invisible, so it reads as no work left.' >&2
    printf 'aiur: pass --label %s:todo for executable work, or --label needs-triage / human:todo\n' "$dispatch_prefix" >&2
    printf '%s\n' 'aiur: to park it deliberately, or --label build-order / epic for a non-runnable container.' >&2
    exit 78
  fi
fi

if [ "$validate_only" -eq 1 ]; then exit 0; fi

admission_resource=$resource
# Identity derivation needs the command's admission decision (resource /
# admission_required), which the classification above just made — so it runs
# here, not at the top of the script, and only for a call that is about to be
# admitted against a metered pool (`budget_derive_identity` re-checks the same
# gates). A local `auth token`/`config` read never pays a GitHub round trip.
budget_derive_identity
# `none` is the shared EndpointPolicy table's pool for endpoints GitHub does
# not meter (`/rate_limit`). They are admitted for ordering but their ledger
# row keeps `resource: none` — the same row the daemon's Budget path writes —
# rather than being booked onto the core bucket, so the guard and the daemon
# cannot disagree about what rate-limit probes cost (#2353). No `none`->core
# mapping is applied: the only admitted `none`-resource command is `api
# rate_limit`, and non-admitted `none` commands (config/auth token) never
# reach the broker.


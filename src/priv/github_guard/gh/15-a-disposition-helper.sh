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

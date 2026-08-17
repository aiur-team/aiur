# Manual end-to-end smoke test for the Aiur event system foundation.
#
# Boots against the live BEAM supervision tree and exercises every
# major brainstorm success criterion: subscription persistence,
# publish → exchange → enqueue fan-out, cursor honor on redelivery,
# tracked-set contamination filter, attention lifecycle, IssueLog
# markers.
#
# Run via:
#
#   cp .aiur/config src/.aiur/config  # if missing
#   mix run scripts/manual_event_flow_e2e.exs
#
# (cwd should be `src/` for the config file path to resolve.)
#
# Tickets exercised: 99, 100, 101 (pre-created via `gh issue create`
# during Ticket A sign-off; see .aiur-test-tickets.json for the pinned
# list). Replace these constants if you re-create the sandbox tickets
# at different numbers.

require Logger

alias Aiur.{IssueLog, Orchestrator}
alias Aiur.Events.{Publisher, SubscriptionStore}

log = fn msg -> IO.puts("\n>>> #{msg}") end

check = fn
  label, true -> IO.puts("  ✓ #{label}")
  label, false -> IO.puts("  ✗ #{label} (FAILED)")
end

# Capture enqueue calls so we can verify delivery
test_pid = self()
SubscriptionStore.set_enqueue_fn(fn id, event -> send(test_pid, {:enqueued, id, event}); :ok end)

# ---------------------------------------------------------------------------
log.("Stage 1: Attach SubscriptionStores for tickets 99, 100, 101")

# Wipe per-issue subscriptions so each run starts fresh (idempotent).
# The `aiur --test --confirm` reset workflow normally handles this;
# we also do it here so the script is safe to run repeatedly without
# requiring a CLI reset between runs.
log_dir = Aiur.Config.Paths.log_root_dir()

for id <- ["99", "100", "101"] do
  SubscriptionStore.stop(id)

  path =
    Path.join(log_dir, "#{Aiur.Config.Paths.repo_name()}.#{id}.subscriptions.json")

  _ = File.rm(path)
end

for id <- ["99", "100", "101"] do
  :ok = SubscriptionStore.attach(id)
  IssueLog.attach(id)
end

snap_100 = SubscriptionStore.snapshot("100")
check.("100 attached with empty subscriptions", snap_100.subscribed_to == [])

# ---------------------------------------------------------------------------
log.("Stage 2: Ticket 100 subscribes to ticket.99.#")

:ok = SubscriptionStore.add_subscription("100", "ticket.99.#", "auto:blocked_by(99)")
snap_100 = SubscriptionStore.snapshot("100")
[binding] = snap_100.subscribed_to
check.("subscription persisted for ticket.99.#", binding["topic"] == "ticket.99.#")

check.(
  "subscription_created_at_event_id snapshot recorded",
  is_integer(binding["subscription_created_at_event_id"])
)

# ---------------------------------------------------------------------------
log.("Stage 3: Mark 99/100/101 as tracked (ETS-backed)")

:ets.insert(Aiur.Orchestrator.TrackedSet, [{"99", true}, {"100", true}, {"101", true}])
check.("99 tracked", Orchestrator.issue_tracked?("99"))
check.("100 tracked", Orchestrator.issue_tracked?("100"))
check.("999 NOT tracked (contamination filter)", not Orchestrator.issue_tracked?("999"))

# ---------------------------------------------------------------------------
log.("Stage 4: Simulate firehose push event from ticket 99")

sha = "live-#{System.unique_integer([:positive])}"

{:ok, id, subscribers} =
  Publisher.publish(
    "ticket.99.branch.push",
    %{
      sha: sha,
      actor: "agent-99",
      ref: "refs/heads/aiur/99",
      commits: [%{"message" => "implement function_a"}]
    },
    issue_number: 99
  )

check.("publish returned :ok with id", is_integer(id))
check.("subscribers = 1 (ticket 100 receives)", subscribers == 1)

# ---------------------------------------------------------------------------
log.("Stage 5: Verify ticket 100 received the event")

receive do
  {:enqueued, "100", event} ->
    check.("ticket_100 received event with matching sha", event.sha == sha)
    check.("event includes topic", event.topic == "ticket.99.branch.push")
    check.("event includes id", event.id == id)
    check.("event includes commits", is_list(event.commits))
after
  2_000 ->
    check.("ticket_100 received event within 2s", false)
end

# ---------------------------------------------------------------------------
log.("Stage 6: Verify cursor advanced (at-least-once contract)")

Process.sleep(100)
snap_100 = SubscriptionStore.snapshot("100")
check.("cursor advanced past event id", snap_100.last_seen_event_id >= id)

# ---------------------------------------------------------------------------
log.("Stage 7: Replay defense (cursor honor)")

[{ss_pid_100, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, "100")
send(ss_pid_100, {:event, %{id: id, topic: "ticket.99.branch.push", sha: sha}})

receive do
  {:enqueued, "100", _} ->
    check.("redelivered event was DROPPED (cursor filter)", false)
after
  200 ->
    check.("redelivered event was DROPPED (cursor filter)", true)
end

# ---------------------------------------------------------------------------
log.("Stage 8: Untracked event filter")

:ok = SubscriptionStore.attach("100")
:ok = SubscriptionStore.add_subscription("100", "ticket.999.#", "test-untracked")
Process.sleep(50)

result = Publisher.publish("ticket.999.branch.push", %{sha: "untracked"}, issue_number: 999)
check.("untracked publish was :filtered", result == :filtered)

# ---------------------------------------------------------------------------
log.("Stage 9: Attention lifecycle (open ❗ → resolve)")

:ok = SubscriptionStore.add_attention("100", "scope-question")
snap = SubscriptionStore.snapshot("100")
check.("attention added to open_attentions", "scope-question" in snap.open_attentions)

:ok = SubscriptionStore.resolve_attention("100", "scope-question")
snap = SubscriptionStore.snapshot("100")
check.("attention cleared after resolve", "scope-question" not in snap.open_attentions)

# ---------------------------------------------------------------------------
log.("Stage 10: IssueLog markers")

Process.sleep(200)
log_path_100 = IssueLog.log_path("100")

if File.exists?(log_path_100) do
  content = File.read!(log_path_100)
  check.("[event:consumed] marker in ticket 100 log", content =~ "[event:consumed]")
else
  check.("IssueLog file exists for ticket 100", false)
end

log_path_99 = IssueLog.log_path("99")

if File.exists?(log_path_99) do
  content = File.read!(log_path_99)

  check.(
    "[event:emit] marker in ticket 99 log (Publisher recorded)",
    content =~ "[event:emit]"
  )
end

# ---------------------------------------------------------------------------
log.("Cleanup")

for id <- ["99", "100", "101"] do
  SubscriptionStore.stop(id)
end

SubscriptionStore.set_enqueue_fn(nil)
:ets.delete_all_objects(Aiur.Orchestrator.TrackedSet)

IO.puts("\n=== ✓ FULL END-TO-END FLOW COMPLETE ===")

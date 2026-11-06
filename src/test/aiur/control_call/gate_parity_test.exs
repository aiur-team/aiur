defmodule Aiur.ControlCall.GateParityTest do
  use ExUnit.Case, async: true

  alias Aiur.ControlCall.Allowlist

  @remote_sh Path.expand("../../../../packaging/npm/aiur-cli/libexec/engine/remote.sh", __DIR__)
  @probes [[:Aiur, :ControlCallTestProbe], [:Aiur, :ControlControllerTestProbe]]

  # Every allowlisted function name -> the client gate word(s) that send it, or why it is never sent.
  # A new allowlisted function must be added here, and a remote word must be in `ensure_remote_command_allowed`.
  @remote %{
    status: ~w(status),
    agents: ~w(agents),
    watch: ~w(watch),
    alerts: ~w(alerts),
    executor_sweep: ~w(executor-sweep),
    rpc: ~w(usage ticket-usage executor-sweep executor-session),
    legacy_accounts: ~w(accounts),
    commands: ~w(commands),
    commands_repair: ~w(commands),
    command_request: ~w(command),
    units: ~w(units),
    feature: ~w(feature),
    lane: ~w(lane),
    epic: ~w(epic),
    build_orders: ~w(build-orders),
    queue: ~w(queue),
    analytics: ~w(analytics),
    history_label_writes: ~w(history),
    github_cost: ~w(github-cost),
    experiments: ~w(experiments),
    capabilities: ~w(capabilities),
    github_usage: ~w(github-usage),
    ticket_estimate: ~w(ticket),
    operator_relay_answer: ~w(operator-relay-answer),
    executor_ack: ~w(executor-ack),
    executor_answer: ~w(executor-answer),
    executor_escalate: ~w(executor-escalate),
    executor_reclassify: ~w(executor-reclassify),
    executor_moot: ~w(executor-moot),
    executor_wait: ~w(executor-wait),
    executor_session: ~w(executor-session),
    executor_roster: ~w(executor-roster),
    executor_fast_forward: ~w(executor-fast-forward),
    executor_claim: ~w(executor-claim),
    executor_release: ~w(executor-release),
    executor_revoke: ~w(executor-revoke),
    executor_emit: ~w(executor-emit),
    executor_subscribe: ~w(executor-subscribe),
    executor_unsubscribe: ~w(executor-unsubscribe),
    executor_subscriptions: ~w(executor-subscriptions),
    todo: ~w(--todo),
    redispatch: ~w(redispatch),
    reset_budget: ~w(reset-budget),
    pause_global: ~w(pause),
    resume_global: ~w(resume),
    set_max_agents: ~w(set),
    set_setting: ~w(set),
    list_settings: ~w(set),
    unset_setting: ~w(set),
    message: ~w(message),
    message_status: ~w(message),
    pause: ~w(pause),
    resume: ~w(resume),
    park: ~w(park),
    take: ~w(take),
    release: ~w(release),
    recover_workspace: ~w(workspace-recover),
    run: ~w(listen-mode)
  }

  # Deny-class or deliberately unsent functions.
  @local_only ~w(operator_answer operator_answer_preview executor_check executor_attach executor_detach
    executor_listen executor_listen_validate usage accounts usage_bar prepare_handoff prepare report main_watch_state
    main_watch_inherited? print_watcher_state publish)a

  defp gate_words do
    src = File.read!(@remote_sh)
    [_, arms] = Regex.run(~r/ensure_remote_command_allowed\(\) \{.*?case "\$command" in\n(.*?)\n\s+;;/s, src)
    words = arms |> String.split("|") |> Enum.map(&(&1 |> String.trim() |> String.trim_trailing(")")))
    # `history` has its own arm because only `history label-writes` is remote.
    if src =~ ~r/\n\s+history\)\n/, do: ["history" | words], else: words
  end

  defp functions do
    for {{segments, fun, _arity}, row} <- Allowlist.entries(), segments not in @probes, do: {fun, row.class}
  end

  test "gate parser finds the accept arm" do
    assert "status" in gate_words()
    assert "redispatch" in gate_words()
  end

  test "every allowlisted function is mapped to a gate word or declared local-only" do
    unmapped = for {fun, _} <- functions(), not Map.has_key?(@remote, fun), fun not in @local_only, uniq: true, do: fun
    assert unmapped == []
  end

  test "every mapped gate word is accepted by the remote gate" do
    gate = gate_words()
    missing = for {fun, words} <- @remote, word <- words, word not in gate, do: {fun, word}
    assert missing == []
  end

  test "deny-class functions are never mapped to a remote word" do
    assert for({fun, :deny} <- functions(), Map.has_key?(@remote, fun), uniq: true, do: fun) == []
  end

  test "mapping has no stale entries" do
    names = MapSet.new(functions(), &elem(&1, 0))
    assert for(fun <- Map.keys(@remote) ++ @local_only, fun not in names, do: fun) == []
  end
end

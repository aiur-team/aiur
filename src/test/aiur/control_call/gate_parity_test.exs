defmodule Aiur.ControlCall.GateParityTest do
  use ExUnit.Case, async: true

  alias Aiur.ControlCall.Allowlist

  @remote_sh Path.expand("../../../../packaging/npm/aiur-cli/libexec/engine/remote.sh", __DIR__)
  @probes [[:Aiur, :ControlCallTestProbe], [:Aiur, :ControlControllerTestProbe]]

  @segs %{
    agent: [:Aiur, :AgentControlCLI],
    handoff: [:Aiur, :Handoff, :CLI],
    session: [:Aiur, :HarnessSessionCLI],
    usage: [:Aiur, :Usage, :CLI],
    ticket_usage: [:Aiur, :TicketUsageCLI],
    sweep: [:Aiur, :ExecutorSweep, :CLI],
    pr_merge: [:Aiur, :PrMerge, :Record],
    listen: [:Aiur, :ListenModeCli]
  }

  # {module, function, arities, client gate words that send it}. Keyed by {segments, function, arity}
  # below, so a new row reusing a name (`rpc`, `run`) or adding an arity is unmapped until listed here.
  # A remote word must be in `ensure_remote_command_allowed`.
  @remote_rows [
    {:agent, :status, [0, 1], ~w(status)},
    {:agent, :agents, [0, 1], ~w(agents)},
    {:agent, :watch, [0, 1], ~w(watch)},
    {:agent, :alerts, [0, 1], ~w(alerts)},
    {:agent, :executor_sweep, [1], ~w(executor-sweep)},
    {:agent, :commands, [0, 1], ~w(commands)},
    {:agent, :commands_repair, [0, 1], ~w(commands)},
    {:agent, :command_request, [1], ~w(command)},
    {:agent, :units, [0, 1], ~w(units)},
    {:agent, :feature, [0, 1], ~w(feature)},
    {:agent, :lane, [0, 1], ~w(lane)},
    {:agent, :epic, [0, 1], ~w(epic)},
    {:agent, :build_orders, [0, 1], ~w(build-orders)},
    {:agent, :queue, [0, 1], ~w(queue)},
    {:agent, :analytics, [0, 1], ~w(analytics)},
    {:agent, :history_label_writes, [1], ~w(history)},
    {:agent, :github_cost, [0, 1], ~w(github-cost)},
    {:agent, :experiments, [0, 1], ~w(experiments)},
    {:agent, :capabilities, [0, 1], ~w(capabilities)},
    {:agent, :github_usage, [0, 1], ~w(github-usage)},
    {:agent, :ticket_estimate, [0, 1], ~w(ticket)},
    {:agent, :operator_relay_answer, [1], ~w(operator-relay-answer)},
    {:agent, :executor_ack, [1], ~w(executor-ack)},
    {:agent, :executor_claim_decision, [1], ~w(executor-claim-decision)},
    {:agent, :executor_release_decision, [1], ~w(executor-release-decision)},
    {:agent, :executor_answer, [1], ~w(executor-answer)},
    {:agent, :executor_escalate, [1], ~w(executor-escalate)},
    {:agent, :executor_reclassify, [1], ~w(executor-reclassify)},
    {:agent, :executor_moot, [1], ~w(executor-moot)},
    {:agent, :executor_wait, [0, 1], ~w(executor-wait)},
    {:agent, :executor_session, [1], ~w(executor-session)},
    {:agent, :executor_roster, [0, 1], ~w(executor-roster)},
    {:agent, :executor_fast_forward, [1, 2], ~w(executor-fast-forward)},
    {:agent, :executor_claim, [0, 1], ~w(executor-claim)},
    {:agent, :executor_release, [0, 1], ~w(executor-release)},
    {:agent, :executor_revoke, [1, 2], ~w(executor-revoke)},
    {:agent, :executor_emit, [2], ~w(executor-emit)},
    {:agent, :executor_subscribe, [1], ~w(executor-subscribe)},
    {:agent, :executor_unsubscribe, [1], ~w(executor-unsubscribe)},
    {:agent, :executor_subscriptions, [0], ~w(executor-subscriptions)},
    {:agent, :todo, [1, 2], ~w(--todo)},
    {:agent, :redispatch, [2], ~w(redispatch)},
    {:agent, :reset_budget, [1], ~w(reset-budget)},
    {:agent, :pause_global, [0], ~w(pause)},
    {:agent, :resume_global, [0], ~w(resume)},
    {:agent, :set_max_agents, [1], ~w(set)},
    {:agent, :set_setting, [2, 3], ~w(set)},
    {:agent, :list_settings, [0, 1], ~w(set)},
    {:agent, :unset_setting, [1, 2], ~w(set)},
    {:agent, :message, [2, 3], ~w(message)},
    {:agent, :message_status, [1], ~w(message)},
    {:agent, :pause, [1], ~w(pause)},
    {:agent, :resume, [1], ~w(resume)},
    {:agent, :park, [1], ~w(park)},
    {:agent, :take, [2], ~w(take)},
    {:agent, :release, [2], ~w(release)},
    {:agent, :recover_workspace, [2], ~w(workspace-recover)},
    {:handoff, :agents, [0], ~w(agents)},
    {:session, :rpc, [1], ~w(executor-session)},
    {:usage, :rpc, [2], ~w(usage)},
    {:usage, :legacy_accounts, [2], ~w(accounts)},
    {:ticket_usage, :rpc, [2], ~w(ticket-usage)},
    {:sweep, :rpc, [1], ~w(executor-sweep)},
    {:listen, :run, [2], ~w(listen-mode)}
  ]

  # Deny-class or deliberately unsent functions.
  @local_rows [
    {:agent, :operator_answer, [1]},
    {:agent, :operator_answer_preview, [1]},
    {:agent, :executor_check, [1]},
    {:agent, :executor_attach, [1]},
    {:agent, :executor_detach, [1]},
    {:agent, :executor_listen, [0, 1]},
    {:agent, :executor_listen_validate, [1]},
    {:agent, :usage, [0, 1, 2]},
    {:agent, :accounts, [1, 2]},
    {:agent, :usage_bar, [1]},
    {:agent, :prepare_handoff, [0, 1]},
    {:agent, :main_watch_state, [0]},
    {:agent, :main_watch_inherited?, [2]},
    {:handoff, :report, [0, 1]},
    {:handoff, :prepare, [0]},
    {:pr_merge, :print_watcher_state, [0]},
    {:pr_merge, :publish, [1]}
  ]

  @remote for {m, f, arities, words} <- @remote_rows, a <- arities, into: %{}, do: {{@segs[m], f, a}, words}
  @local for {m, f, arities} <- @local_rows, a <- arities, into: MapSet.new(), do: {@segs[m], f, a}

  defp gate_words do
    src = File.read!(@remote_sh)
    [_, arms] = Regex.run(~r/ensure_remote_command_allowed\(\) \{.*?case "\$command" in\n(.*?)\n\s+;;/s, src)
    words = arms |> String.split("|") |> Enum.map(&(&1 |> String.trim() |> String.trim_trailing(")")))
    # `history` has its own arm because only `history label-writes` is remote.
    if src =~ ~r/\n\s+history\)\n/, do: ["history" | words], else: words
  end

  defp functions do
    for {{segments, _fun, _arity} = key, row} <- Allowlist.entries(), segments not in @probes, do: {key, row.class}
  end

  # Allowlisted keys that are neither client-mapped nor declared local-only.
  defp unmapped(keys, remote, local), do: for(k <- keys, not Map.has_key?(remote, k), k not in local, do: k)

  test "gate parser finds the accept arm" do
    assert "status" in gate_words()
    assert "redispatch" in gate_words()
  end

  test "a new row reusing a mapped function name or adding an arity is unmapped" do
    keys = [{[:Aiur, :Other, :CLI], :rpc, 1}, {[:Aiur, :AgentControlCLI], :status, 2}, {[:Aiur, :AgentControlCLI], :status, 1}]
    assert unmapped(keys, @remote, @local) == [{[:Aiur, :Other, :CLI], :rpc, 1}, {[:Aiur, :AgentControlCLI], :status, 2}]
  end

  test "every allowlisted function is mapped to a gate word or declared local-only" do
    assert unmapped(Enum.map(functions(), &elem(&1, 0)), @remote, @local) == []
  end

  test "every mapped gate word is accepted by the remote gate" do
    gate = gate_words()
    missing = for {key, words} <- @remote, word <- words, word not in gate, do: {key, word}
    assert missing == []
  end

  test "deny-class functions are never mapped to a remote word" do
    assert for({key, :deny} <- functions(), Map.has_key?(@remote, key), do: key) == []
  end

  test "mapping has no stale entries" do
    keys = MapSet.new(functions(), &elem(&1, 0))
    assert for(key <- Map.keys(@remote) ++ MapSet.to_list(@local), key not in keys, do: key) == []
  end
end

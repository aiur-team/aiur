defmodule Aiur.Capabilities.CoreProvidersTest do
  use ExUnit.Case, async: true
  alias Aiur.DecisionStore.CapabilityProvider, as: Commands
  alias Aiur.Executor.CapabilityProvider, as: Executor
  alias Aiur.HttpServer.CapabilityProvider, as: Http
  alias Aiur.Orchestrator.CapabilityProvider, as: Orchestration
  alias Aiur.Tracker.CapabilityProvider, as: Tracker

  @context %{run_shape: %{http_listener: true}, settings: %{observability: %{dashboard_writable: true}, tracker: %{kind: "github"}}}
  @available %{state: :available}
  @unknown %{state: :unknown, reason: :unknown}

  defp inputs(overrides \\ []) do
    Keyword.merge([lookup_fun: fn _ -> self() end, http_port_fun: fn -> 4000 end, snapshot_fun: fn -> {:current, %{}, %{}} end, token: String.duplicate("a", 32)], overrides)
  end

  for {condition, shape, port, reason} <- [{"no dashboard", false, 4000, :not_installed}, {"absent listener", true, nil, :not_running}, {"bound listener", true, 4000, nil}] do
    test "api.http: #{condition}" do
      context = put_in(@context.run_shape.http_listener, unquote(shape))
      expected = if unquote(reason), do: %{state: :unavailable, reason: unquote(reason)}, else: @available
      assert Http.evaluate(context, inputs(http_port_fun: fn -> unquote(port) end))["api.http"] == expected
    end
  end

  test "orchestration: dead process with cached snapshot is not_running" do
    assert Orchestration.evaluate(@context, inputs(lookup_fun: fn _ -> nil end))["orchestration"] == %{state: :unavailable, reason: :not_running}
  end

  test "orchestration: a fresh snapshot behind a busy mailbox stays available" do
    name = :"capability_orchestrator_#{System.unique_integer([:positive])}"
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(pid, name)
    send(pid, :backlog)
    :ok = Aiur.Orchestrator.SnapshotStore.publish(name, %{})
    on_exit(fn -> Aiur.Orchestrator.SnapshotStore.discard(name) end)
    Process.sleep(5)
    assert Orchestration.evaluate(@context, orchestrator: name)["orchestration"] == @available
  end

  for {condition, snapshot, expected} <- [
        {"unpublished", :snapshot_unpublished, %{state: :degraded, reason: :snapshot_unpublished}},
        {"stale", {:stale, %{}, %{observed_at: "2026-10-09T00:00:00Z"}}, %{state: :degraded, reason: :snapshot_stale, observed_at: "2026-10-09T00:00:00Z"}},
        {"current", {:current, %{}, %{}}, %{state: :available}}
      ] do
    test "orchestration: #{condition}" do
      assert Orchestration.evaluate(@context, inputs(snapshot_fun: fn -> unquote(Macro.escape(snapshot)) end))["orchestration"] == unquote(Macro.escape(expected))
    end
  end

  test "degraded snapshot degrades status but agents can still run and receive messages" do
    caps = Orchestration.evaluate(@context, inputs(snapshot_fun: fn -> :snapshot_unpublished end))
    assert caps["instance.status"] == %{state: :degraded, reason: :dependency_unavailable, depends_on: ["orchestration"]}
    assert caps["agents.run"] == @available
    assert caps["agents.message"] == @available
  end

  test "orchestrator unavailable propagates to status and agent operations" do
    caps = Orchestration.evaluate(@context, inputs(lookup_fun: fn _ -> nil end))

    for id <- ~w(instance.status agents.run agents.message) do
      assert caps[id].reason == :dependency_unavailable
      assert caps[id].depends_on == ["orchestration"]
    end

    assert caps["instance.status"].state == :degraded
    assert caps["agents.run"].state == :unavailable
    assert caps["agents.message"].state == :unavailable
  end

  for writable <- [false, :unknown] do
    test "agents.message and commands.answer: writable #{writable}" do
      context = if unquote(writable) == :unknown, do: %{@context | settings: :unavailable}, else: put_in(@context.settings.observability.dashboard_writable, false)
      expected = if unquote(writable) == :unknown, do: @unknown, else: %{state: :unavailable, reason: :disabled}
      assert Orchestration.evaluate(context, inputs())["agents.message"] == expected
      assert Commands.evaluate(context, inputs())["commands.answer"] == expected
    end
  end

  test "healthy operations are available and Command answers are versioned" do
    caps = Orchestration.evaluate(@context, inputs())
    for id <- ~w(orchestration instance.status agents.run agents.message), do: assert(caps[id] == @available)
    caps = Commands.evaluate(@context, inputs())
    assert caps["commands.read"] == @available
    assert caps["commands.answer"] == %{state: :available, version: 1}
    assert caps["commands.supervisor_api"] == @available
  end

  test "commands.read and answer: missing store takes precedence over HTTP" do
    caps = Commands.evaluate(@context, inputs(lookup_fun: fn _ -> nil end, http_port_fun: fn -> nil end))
    for id <- ~w(commands.read commands.answer), do: assert(caps[id] == %{state: :unavailable, reason: :not_running})
  end

  test "commands.answer: orchestrator down is degraded, not unavailable" do
    lookup = fn
      Aiur.DecisionStore -> self()
      Aiur.Orchestrator -> nil
    end

    caps = Commands.evaluate(@context, inputs(lookup_fun: lookup))
    assert caps["commands.read"] == @available
    assert caps["commands.answer"] == %{state: :degraded, reason: :dependency_unavailable, depends_on: ["orchestration"]}
  end

  for token <- [nil, "", "invalid"] do
    test "commands.supervisor_api: token #{inspect(token)} never leaks" do
      caps = Commands.evaluate(@context, inputs(token: unquote(token)))
      expected = if unquote(token) == "invalid", do: @unknown, else: %{state: :unavailable, reason: :not_configured}
      assert caps["commands.supervisor_api"] == expected
      refute inspect(caps) =~ "token:"
    end
  end

  for shape <- [false, true] do
    test "api-dependent IDs: listener shape #{shape} without a bound port" do
      context = put_in(@context.run_shape.http_listener, unquote(shape))
      opts = inputs(http_port_fun: fn -> nil end)
      caps = Map.merge(Orchestration.evaluate(context, opts), Commands.evaluate(context, opts))

      for id <- ~w(agents.message commands.read commands.answer commands.supervisor_api) do
        assert caps[id] == %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["api.http"]}
      end
    end
  end

  for kind <- ~w(github linear memory) do
    test "tracker: configured #{kind}" do
      caps = Tracker.capabilities(put_in(@context.settings.tracker.kind, unquote(kind)))

      for id <- ~w(github linear) do
        expected = if id == unquote(kind), do: @available, else: %{state: :unavailable, reason: :not_configured}
        assert caps["tracker." <> id] == expected
      end
    end
  end

  test "tracker: unavailable settings is unknown" do
    assert Tracker.capabilities(%{@context | settings: :unavailable}) == %{"tracker.github" => @unknown, "tracker.linear" => @unknown}
  end

  for {kind, identity, expected} <- [
        {"github", "owner/repo", %{kind: "github", owner: "owner", name: "repo"}},
        {"linear", "slug", %{kind: "linear", owner: nil, name: "slug"}},
        {"memory", "memory", %{kind: "memory", owner: nil, name: "memory"}},
        {"github", nil, nil},
        {"github", "invalid", nil},
        {"github", "owner/repo/extra", nil}
      ] do
    test "repository: #{kind} #{inspect(identity)}" do
      context = put_in(@context.settings.tracker.kind, unquote(kind))
      assert Tracker.repository(context, identity_fun: fn -> unquote(identity) end) == %{repository: unquote(Macro.escape(expected))}
    end
  end

  test "repository: failed identity read is nil" do
    assert Tracker.repository(@context, identity_fun: fn -> raise "failed" end) == %{repository: nil}
    assert Tracker.repository(@context, identity_fun: fn -> exit(:failed) end) == %{repository: nil}
  end

  test "executor: wakes require inbox and conversations are not managed" do
    assert Executor.evaluate(@context, inputs())["executor.wakes"] == @available
    caps = Executor.evaluate(@context, inputs(lookup_fun: fn _ -> nil end))
    assert caps["executor.wakes"] == %{state: :unavailable, reason: :not_running}
    assert caps["executor.conversation"] == %{state: :unavailable, reason: :executor_not_managed}
  end

  for state <- ~w(active idle stalled expired unknown) do
    test "executor: owner state #{state} is preserved in a mixed roster" do
      state = unquote(state)

      section =
        Executor.executor(@context,
          owner_fun: fn _ -> {:ok, %{"id" => "owner"}} end,
          roster_fun: fn _ -> %{executors: [%{id: "peer", state: :stalled}, %{id: "owner", state: String.to_existing_atom(state)}]} end
        )

      assert section == %{executor: %{state: state, consumer_id: "owner", harness: nil}}
      assert Executor.live?(section.executor) == state in ["active", "idle"]
    end
  end

  for {name, entries, state} <- [{"no claims", [], "absent"}, {"expired claims", [%{state: :expired}], "expired"}, {"unowned live claims", [%{state: :idle}], "unknown"}] do
    test "executor: #{name}" do
      assert Executor.executor(@context, owner_fun: fn _ -> :none end, roster_fun: fn _ -> %{executors: unquote(Macro.escape(entries))} end) == %{executor: %{state: unquote(state), consumer_id: nil}}
    end
  end

  test "executor: raising or exiting roster is unknown, not absent" do
    for roster <- [fn _ -> raise "failed" end, fn _ -> exit(:failed) end] do
      assert Executor.executor(@context, owner_fun: fn _ -> :none end, roster_fun: roster) == %{executor: %{state: "unknown"}}
    end
  end
end

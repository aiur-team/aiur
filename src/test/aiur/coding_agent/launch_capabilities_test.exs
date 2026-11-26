defmodule Aiur.CodingAgent.LaunchCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.SessionStartup
  alias Aiur.CodingAgent
  alias Aiur.Issue

  defmodule PrimaryTelemetry do
    def prepare_launch(issue, opts) do
      send(self(), {:prepare, :primary, issue.id, opts})
      {:ok, %{id: make_ref()}}
    end

    def revoke(launch) do
      send(self(), {:revoke, :primary, launch})
      :ok
    end
  end

  defmodule FallbackTelemetry do
    def prepare_launch(issue, opts) do
      send(self(), {:prepare, :fallback, issue.id, opts})
      {:ok, %{id: make_ref()}}
    end

    def revoke(launch) do
      send(self(), {:revoke, :fallback, launch})
      :ok
    end
  end

  defmodule UnavailableTelemetry do
    def prepare_launch(_issue, _opts), do: {:error, :telemetry_unavailable}
    def revoke(_launch), do: raise("must not revoke an unprepared launch")
  end

  defp registry do
    %{
      "claude-repl" => %{launch_telemetry: PrimaryTelemetry},
      "claude" => %{launch_telemetry: FallbackTelemetry},
      "new-harness" => %{launch_telemetry: PrimaryTelemetry},
      "codex" => %{}
    }
  end

  test "launch telemetry is prepared only for backends that declare it, independent of their name" do
    issue = %Issue{id: "launch-capabilities"}
    opts = [launch_telemetry_registry: registry(), backend: "new-harness", attempt_id: "attempt"]
    assert {:ok, nil} = CodingAgent.prepare_launch_telemetry("codex", issue, opts)
    refute_received {:prepare, _, _, _}
    assert {:ok, %{id: id}} = CodingAgent.prepare_launch_telemetry("new-harness", issue, opts)
    assert is_reference(id)
    assert_received {:prepare, :primary, "launch-capabilities", forwarded}
    assert forwarded == [backend: "new-harness", attempt_id: "attempt"]
  end

  test "revoke is a no-op for nil and absent capabilities, otherwise uses the preparing backend" do
    opts = [launch_telemetry_registry: registry()]
    launch = %{id: make_ref()}
    assert :ok = CodingAgent.revoke_launch_telemetry("claude-repl", nil, opts)
    assert :ok = CodingAgent.revoke_launch_telemetry("codex", launch, opts)
    assert :ok = CodingAgent.revoke_launch_telemetry("unknown", launch, opts)
    refute_received {:revoke, _, _}
    assert :ok = CodingAgent.revoke_launch_telemetry("claude-repl", launch, opts)
    assert_received {:revoke, :primary, ^launch}
  end

  test "startup prepares declared telemetry for a backend outside the former name allowlist" do
    issue = %Issue{id: "new-harness-launch"}
    opts = [backend: "new-harness", attempt_id: "attempt", launch_telemetry_registry: registry()]
    start_fun = fn _workspace, opts -> {:ok, %{launch_seen: opts[:telemetry_launch]}} end

    assert {:ok, %{backend: "new-harness", telemetry_launch: %{id: id}, launch_seen: %{id: id}}} =
             SessionStartup.start_with_telemetry("/ws", issue, "worker", %{lease: :test}, opts, start_fun, self())

    assert_received {:prepare, :primary, "new-harness-launch", forwarded}
    assert forwarded[:backend] == "new-harness"
    assert forwarded[:workspace_ownership] == %{lease: :test}
    assert forwarded[:execution_recipient] == self()
    assert forwarded[:worker_host] == "worker"
    refute_received {:revoke, _, _}
  end

  test "fallback guards existing revoke-before-prepare timing using each backend's telemetry module" do
    issue = %Issue{id: "fallback-launch"}
    opts = [backend: "claude-repl", launch_telemetry_registry: registry()]

    start_fun = fn _workspace, opts ->
      send(self(), {:start, opts[:backend], opts[:telemetry_launch]})
      {:error, :spawn_failed}
    end

    assert {:error, :spawn_failed} =
             SessionStartup.start_with_telemetry("/ws", issue, nil, %{lease: :test}, opts, start_fun, nil)

    # Consume in mailbox order: selective receive alone would not pin ordering.
    assert {:prepare, :primary, "fallback-launch", _} = next_event()
    assert {:start, "claude-repl", primary} = next_event()
    assert {:revoke, :primary, ^primary} = next_event()
    assert {:prepare, :fallback, "fallback-launch", fallback_opts} = next_event()
    assert fallback_opts[:backend] == "claude"
    assert {:start, "claude", fallback} = next_event()
    assert {:revoke, :fallback, ^fallback} = next_event()
    assert {:revoke, :primary, ^primary} = next_event()
  end

  test "telemetry preparation errors propagate without spawning a session" do
    opts = [backend: "new-harness", launch_telemetry_registry: %{"new-harness" => %{launch_telemetry: UnavailableTelemetry}}]
    start_fun = fn _, _ -> flunk("must not start without prepared telemetry") end

    assert {:error, :telemetry_unavailable} =
             SessionStartup.start_with_telemetry("/ws", %Issue{}, nil, %{lease: :test}, opts, start_fun, nil)
  end

  test "production registry declares telemetry on both transports and display only on the REPL" do
    entries = CodingAgent.backends()
    assert entries["claude"][:launch_telemetry] == Aiur.Claude.Telemetry
    assert CodingAgent.child_specs() == [Aiur.Claude.Telemetry]
    assert entries["claude-repl"][:launch_telemetry] == Aiur.Claude.Telemetry
    assert CodingAgent.display_tailer("claude-repl") == Aiur.Claude.DisplayTailer
    assert CodingAgent.display_tailer("claude") == nil
    assert CodingAgent.display_tailer("codex") == nil
    assert CodingAgent.display_tailer("unknown") == nil
  end

  defp next_event do
    receive do
      event -> event
    after
      0 -> flunk("missing synchronous telemetry event")
    end
  end
end

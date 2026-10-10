defmodule Aiur.CapabilitiesInputFailureTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Aiur.Capabilities.{Monitor, Table}

  defmodule InputProvider do
    @behaviour Aiur.Capabilities.Provider
    @impl true
    def capability_ids do
      case Agent.get(__MODULE__, & &1) do
        :healthy -> ["identity"]
        {:raise, message} -> raise message
        :throw -> throw(:broken_ids)
      end
    end

    @impl true
    def capabilities(_context), do: %{"identity" => %{state: :available}}
  end

  setup do
    start_supervised!(%{id: InputProvider, start: {Agent, :start_link, [fn -> {:raise, "broken IDs"} end, [name: InputProvider]]}})
    table = String.to_atom("capabilities_input_#{System.unique_integer([:positive])}")
    tasks = start_supervised!({Task.Supervisor, name: nil})
    opts = [table: table, providers: [InputProvider], task_supervisor: tasks, name: nil, tick_ms: 60_000]
    children = [{Table, table: table, name: nil}, {Monitor, opts}, %{id: :sibling, start: {Agent, :start_link, [fn -> :sibling end]}}]
    %{opts: opts, children: children}
  end

  test "raising ID input preserves monitor and rest_for_one siblings on first tick and refresh", %{opts: opts, children: children} do
    log =
      capture_log(fn ->
        supervisor = start_supervised!(%{id: :registry, start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}})
        pids = child_pids(supervisor)
        monitor = pids[Monitor]
        :sys.get_state(monitor)
        assert_unknown(opts, "broken IDs")
        assert Process.alive?(monitor)
        assert child_pids(supervisor) == pids

        for input <- [:healthy, {:raise, "broken IDs"}, {:raise, "different failure"}, {:raise, "different failure"}] do
          Agent.update(InputProvider, fn _ -> input end)
          GenServer.cast(monitor, :refresh)
          :sys.get_state(monitor)

          case input do
            :healthy -> assert Aiur.Capabilities.report(opts).capabilities["identity"] == %{state: :available}
            {:raise, message} -> assert_unknown(opts, message)
          end

          assert Process.alive?(monitor)
          assert child_pids(supervisor) == pids
        end
      end)

    assert length(Regex.scan(~r/capability_registry.*broken IDs/, log)) == 1
    assert length(Regex.scan(~r/capability_registry.*different failure/, log)) == 1
  end

  test "thrown ID input is unknown on the synchronous fallback read", %{opts: opts} do
    Agent.update(InputProvider, fn _ -> :throw end)
    assert_unknown(opts, "broken_ids")
  end

  defp assert_unknown(opts, detail) do
    report = Aiur.Capabilities.report(opts)
    assert report.instance == nil
    assert report.machine == nil
    assert %{state: :unknown, reason: :unknown, detail: actual} = report.capabilities["identity"]
    assert actual =~ detail
    assert report.capabilities["build_queue"] == report.capabilities["identity"]
    assert Aiur.Capabilities.to_wire(report)["capabilities"]["identity"] == %{"state" => "unknown", "reason" => "unknown"}
  end

  defp child_pids(supervisor), do: Map.new(Supervisor.which_children(supervisor), fn {id, pid, _type, _modules} -> {id, pid} end)
end

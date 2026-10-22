defmodule Aiur.TestRunOverridesTest do
  # `aiurdev --test` beside the live daemon (#5121): the sandbox run caps at its
  # pinned tickets, ignores host load gates, and takes a free dashboard port.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Config.{Schema, TestRunOverrides}
  alias Aiur.HttpServer

  setup do
    previous_endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)

    on_exit(fn ->
      if previous_endpoint,
        do: Application.put_env(:aiur, AiurWeb.Endpoint, previous_endpoint),
        else: Application.delete_env(:aiur, AiurWeb.Endpoint)
    end)
  end

  defp parsed do
    Schema.parse(%{
      "agent" => %{
        "max_concurrent_agents" => 16,
        "max_cpu_pressure" => 20.0,
        "max_load_average" => 1.5
      }
    })
  end

  test "an ordinary run keeps the configured capacity gates" do
    System.delete_env("AIUR_DEV_TEST_TICKET_IDS")
    {:ok, settings} = TestRunOverrides.apply(parsed())

    assert settings.agent.max_concurrent_agents == 16
    assert settings.agent.max_cpu_pressure == 20.0
    assert settings.agent.max_load_average == 1.5
  end

  test "a sandbox run caps at its pinned tickets and drops host load gates" do
    Aiur.TestScopeGuard.put_ticket_scope!("2897")
    {:ok, %{agent: agent}} = TestRunOverrides.apply(parsed())

    assert agent.max_concurrent_agents == 1
    assert agent.max_concurrent_agents_by_state == %{}

    assert [nil, nil, nil, nil, nil] == [
             agent.max_cpu_pressure,
             agent.target_cpu_pressure,
             agent.max_load_average,
             agent.target_load_average,
             agent.run_queue_threshold
           ]

    Aiur.TestScopeGuard.put_ticket_scope!("2897,2898,2899")
    assert {:ok, %{agent: %{max_concurrent_agents: 3}}} = TestRunOverrides.apply(parsed())
  end

  test "parse errors pass through" do
    assert TestRunOverrides.apply({:error, :bad}) == {:error, :bad}
  end

  describe "dashboard port in use" do
    defp start_with_busy_port do
      calls = start_supervised!({Agent, fn -> 0 end})

      start_fun = fn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}}
          _ -> :ignore
        end
      end

      log =
        capture_log(fn ->
          assert HttpServer.start_link(
                   host: "127.0.0.1",
                   port: 4000,
                   dashboard_writable: false,
                   endpoint_start_fun: start_fun
                 ) == :ignore
        end)

      {Agent.get(calls, & &1), log}
    end

    test "a sandbox run retries on a free port" do
      Aiur.TestScopeGuard.put_ticket_scope!("2897")
      {calls, log} = start_with_busy_port()

      assert calls == 2
      assert log =~ "binds a free port instead"
      assert Application.get_env(:aiur, AiurWeb.Endpoint)[:http][:port] == 0
    end

    test "an ordinary run still disables the dashboard" do
      System.delete_env("AIUR_DEV_TEST_TICKET_IDS")
      {calls, log} = start_with_busy_port()

      assert calls == 1
      assert log =~ "Dashboard disabled for this instance"
    end
  end
end

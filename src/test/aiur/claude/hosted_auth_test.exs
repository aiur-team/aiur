defmodule Aiur.Claude.HostedAuthTest do
  use ExUnit.Case, async: false

  import Aiur.Codex.TurnLoopTestSupport

  alias Aiur.Claude.{AccountGeneration, AccountMeters, CodingAgent.Methods, MeterTestSupport}
  alias Aiur.ProviderAccountGeneration

  @now ~U[2026-10-24 12:00:00Z]

  setup do
    MeterTestSupport.account_meter_context(@now)
  end

  test "hosted Claude accepts API-key auth and rejects subscription auth", %{owner: owner, session: session, binding: binding} do
    hosted = Map.put(session, :instance_mode, "hosted")

    assert {:ok, ^binding} = AccountGeneration.observe(hosted, :api_key)
    assert %{generation: generation, freshness: :current, health: :healthy} = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding)
    assert is_binary(generation)

    assert AccountGeneration.observe(hosted, :subscription) ==
             {:error, {:unsafe_hosted_authentication, "claude", :subscription}}

    assert %{generation: nil} = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding)
  end

  test "hosted Claude fails closed on an unknown observation", %{owner: owner, session: session, binding: binding} do
    hosted = Map.put(session, :instance_mode, "hosted")

    assert AccountGeneration.observe(hosted, :unknown) ==
             {:error, {:unsafe_hosted_authentication, "claude", :unknown}}

    assert %{generation: nil} = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding)
  end

  test "local Claude subscription observations remain accepted", %{session: session, binding: binding} do
    assert {:ok, ^binding} = AccountGeneration.observe(session, :subscription)
  end

  test "a subscription rate-limit observation terminates hosted handling without ingesting", %{session: session} do
    test_pid = self()

    hosted =
      Map.merge(session, %{
        instance_mode: "hosted",
        provider_meter_ingester: fn update ->
          send(test_pid, {:ingested, update})
          {:ok, update}
        end
      })

    assert AccountMeters.handle_notification(hosted, MeterTestSupport.fixture("rate-limit-subscription.json"), observed_at: @now) ==
             {:error, {:unsafe_hosted_authentication, "claude", :subscription}}

    refute_received {:ingested, _update}
  end

  test "hosted tool calls fail before invoking the tool when auth is unverified", %{session: session} do
    port = open_cat_port()
    test_pid = self()
    on_exit(fn -> close_port(port) end)

    hosted = Map.merge(session, %{instance_mode: "hosted", port: port, workspace: "/ws", thread_id: "thread-1"})

    state =
      base_state()
      |> Map.put(:tool_executor, fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})
        %{"success" => true}
      end)

    payload = %{
      "method" => "item/tool/call",
      "id" => 101,
      "params" => %{"name" => "emit_event", "callId" => "call-101", "arguments" => %{"name" => "progress"}}
    }

    assert Methods.handle_method(hosted, state, payload, Jason.encode!(payload), "item/tool/call") ==
             {:error, {:turn_unretryable, {:unsafe_hosted_authentication, "claude", :unknown}}}

    refute_received {:tool_called, _tool, _arguments}
  end

  test "hosted completion fails while auth is unverified", %{session: session} do
    port = open_cat_port()
    on_exit(fn -> close_port(port) end)
    hosted = Map.merge(session, %{instance_mode: "hosted", port: port})
    payload = %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}}

    assert Methods.handle_method(hosted, base_state(), payload, Jason.encode!(payload), "turn/completed") ==
             {:error, {:turn_unretryable, {:unsafe_hosted_authentication, "claude", :unknown}}}
  end
end

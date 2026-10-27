defmodule Aiur.Listener.SchedulerTest do
  use ExUnit.Case, async: false
  alias Aiur.Listener.{Effective, Scheduler}
  alias Aiur.Orchestrator.OperatorMessages.DeliveryPolicy

  setup do
    warning_key = {Scheduler, :invalid_flag_warned}
    warning_before = :persistent_term.get(warning_key, :not_present)
    :persistent_term.put(warning_key, false)

    on_exit(fn ->
      if warning_before == :not_present, do: :persistent_term.erase(warning_key), else: :persistent_term.put(warning_key, warning_before)
    end)

    previous = Application.fetch_env(:aiur, :listener_send_routing)
    Application.delete_env(:aiur, :listener_send_routing)

    on_exit(fn ->
      case previous do
        {:ok, flag} -> Application.put_env(:aiur, :listener_send_routing, flag)
        :error -> Application.delete_env(:aiur, :listener_send_routing)
      end
    end)
  end

  test "unset flag retains legacy policies even with a usable spec" do
    assert Scheduler.routing(spec_status: :ok) == :legacy

    for interrupt <- [true, false], immediate <- [true, false], {origin, policy, fallback} <- [{:agent_chat, :interrupt, :queue_next}, {:http, :checkpoint, nil}, {:tui, :auto, nil}] do
      caps = %{can_interrupt: interrupt, immediate_delivery: immediate}
      assert Scheduler.resolve(origin, %{effective: :sync}, caps, nil, spec_status: :ok) == DeliveryPolicy.normalize_delivery_request(policy, fallback, caps)
    end

    assert Scheduler.resolve(:internal, nil, %{}, nil) == {:error, :invalid_message}
  end

  test "listener flag requires usable installed spec and rejects misspelled flags" do
    Application.put_env(:aiur, :listener_send_routing, :listener)
    assert Scheduler.routing(spec_status: :ok) == :listener

    for status <- [{:error, :not_installed}, {:error, :spec_invalid}] do
      assert Scheduler.routing(spec_status: status) == :legacy
      assert Scheduler.resolve(:agent_chat, %{effective: :sync}, %{can_interrupt: true}, nil, spec_status: status) == {:ok, delivery_policy: :interrupt, fallback: :queue_next}
    end

    if not Code.ensure_loaded?(Module.concat([Aiur, Listener, Spec])), do: assert(Scheduler.spec_status() == {:error, :not_installed})
    Application.put_env(:aiur, :listener_send_routing, :misspelled)
    assert Scheduler.routing(spec_status: :ok) == :legacy
  end

  test "listener policies use effective mode and reject unavailable or unwired views" do
    Application.put_env(:aiur, :listener_send_routing, :listener)

    for origin <- [:agent_chat, :http, :tui, :internal] do
      assert Scheduler.resolve(origin, %{effective: :sync}, %{}, nil, spec_status: :ok) == {:ok, delivery_policy: :checkpoint, listener_mode: :sync}
      assert Scheduler.resolve(origin, %{effective: :async}, %{}, nil, spec_status: :ok) == {:ok, listener_mode: :async}

      for view <- [nil, %{effective: nil}, %{effective: :steer, support: %{steer: %{carrier: :native}}}] do
        assert Scheduler.resolve(origin, view, %{}, nil, spec_status: :ok) == {:error, :listener_mode_unavailable}
      end
    end
  end

  test "emulated steer requires explicit effective support acceptance" do
    Application.put_env(:aiur, :listener_send_routing, :listener)
    harness = %{source: :session, harness_id: "codex", callbacks: %{steer: :none}, primitives: %{turn_boundary_start: true, hard_interrupt: :in_band, pull_tool: false}}
    record = %{requested: :steer, version: 0, actor: :human}
    view = Effective.compute(record, harness)
    assert Scheduler.resolve(:agent_chat, view, %{}, nil, spec_status: :ok) == {:ok, delivery_policy: :checkpoint, listener_mode: :sync}
    view = Effective.compute(record, harness, emulated_interrupt_accepted?: true)
    assert Scheduler.resolve(:agent_chat, view, %{}, nil, spec_status: :ok) == {:ok, delivery_policy: :interrupt, fallback: :queue_next, listener_mode: :steer, steer_carrier: :emulated_interrupt}
  end
end

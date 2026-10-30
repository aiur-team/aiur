defmodule Aiur.Listener.SchedulerTest do
  use ExUnit.Case, async: false
  alias Aiur.Listener.{Effective, Scheduler}

  test "no production code or config references the removed listener routing flag" do
    root = Path.expand("../../..", __DIR__)
    files = Path.wildcard(Path.join(root, "{lib,config}/**/*.{ex,exs}"))
    assert files != []
    assert Enum.filter(files, &(File.read!(&1) =~ "listener_send_routing")) == []
  end

  test "default uses sync for every conversation origin with a usable spec" do
    assert Scheduler.routing(spec_status: :ok) == :listener

    for interrupt <- [true, false], immediate <- [true, false], origin <- [:agent_chat, :voice_assistant, :http, :tui, :internal] do
      caps = %{can_interrupt: interrupt, immediate_delivery: immediate}
      assert Scheduler.resolve(origin, %{effective: :sync}, caps, nil, spec_status: :ok) == {:ok, delivery_policy: :checkpoint, listener_mode: :sync}
    end
  end

  test "unusable spec refuses conversation delivery without falling back to interrupt" do
    for status <- [{:error, :not_installed}, {:error, :spec_invalid}, :unknown] do
      assert Scheduler.routing(spec_status: status) == :unavailable
      assert Scheduler.resolve(:agent_chat, %{effective: :sync}, %{can_interrupt: true}, nil, spec_status: status) == {:error, :listener_mode_unavailable}
    end
  end

  test "listener policies use effective mode and reject unavailable or unwired views" do
    for origin <- [:agent_chat, :http, :tui, :internal] do
      assert Scheduler.resolve(origin, %{effective: :sync}, %{}, nil, spec_status: :ok) == {:ok, delivery_policy: :checkpoint, listener_mode: :sync}
      assert Scheduler.resolve(origin, %{effective: :async}, %{}, nil, spec_status: :ok) == {:ok, listener_mode: :async}

      for view <- [nil, %{effective: nil}] do
        assert Scheduler.resolve(origin, view, %{}, nil, spec_status: :ok) == {:error, :listener_mode_unavailable}
      end
    end
  end

  test "held bodies stay pull-only only while actual async support is usable" do
    delivery = Aiur.AgentQueue.operator_message("held", "private", listener_mode: :async).delivery

    for status <- [:proven, :experimental] do
      view = %{effective: :sync, support: %{async: %{status: status}}}
      assert Scheduler.restamp_fun(view).(delivery) == delivery
    end

    for support <- [%{}, %{async: %{status: :unknown}}, %{async: %{status: :unsupported, reason: :pull_tool_unavailable}}] do
      restamped = Scheduler.restamp_fun(%{effective: :sync, support: support}).(delivery)
      assert restamped.consume_at == :safe_checkpoint
      assert restamped.listener_mode_at_claim == :sync
    end

    assert Scheduler.restamp_fun(%{effective: :sync}).(delivery).consume_at == :safe_checkpoint
  end

  test "emulated steer requires explicit effective support acceptance" do
    harness = %{source: :session, harness_id: "codex", callbacks: %{steer: :none}, primitives: %{turn_boundary_start: true, hard_interrupt: :in_band, pull_tool: false}}
    record = %{requested: :steer, version: 0, actor: :human}
    view = Effective.compute(record, harness)
    assert Scheduler.resolve(:agent_chat, view, %{}, nil, spec_status: :ok) == {:ok, delivery_policy: :checkpoint, listener_mode: :sync}
    view = Effective.compute(record, harness, emulated_interrupt_accepted?: true)
    assert Scheduler.resolve(:agent_chat, view, %{}, nil, spec_status: :ok) == {:ok, delivery_policy: :interrupt, fallback: :queue_next, listener_mode: :steer, steer_carrier: :emulated_interrupt}
  end
end

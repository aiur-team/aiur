defmodule Aiur.Listener.EffectiveTest do
  use ExUnit.Case, async: true

  alias Aiur.Harness.Capabilities
  alias Aiur.Listener.Effective

  @profiles [
    {"codex", :proven, :in_band, true},
    {"claude", :proven, :in_band, true},
    {"claude-repl", :experimental, :out_of_band, false},
    {"muse", :proven, :in_band, true},
    {"kimi", :proven, :none, true},
    {"deepseek", :proven, :none, true},
    {"openrouter", :proven, :none, true}
  ]

  for {backend, sync_status, interrupt, pull} <- @profiles,
      requested <- [:sync, :steer, :async],
      accepted <- [false, true],
      installed <- [false, true] do
    @backend backend
    @sync_status sync_status
    @interrupt interrupt
    @pull pull
    @requested requested
    @accepted accepted
    @installed installed
    test "#{backend} requested #{requested}, interrupt acceptance #{accepted}, pull installed #{installed}" do
      result = Effective.compute(record(@requested), harness(@backend), emulated_interrupt_accepted?: @accepted, pull_tool_installed?: @installed)

      {steer, async_support} = expected_support(@interrupt, @accepted, @pull, @installed)
      {effective, reason} = expected_effective(@requested, steer, async_support)

      assert result == %{
               requested: @requested,
               effective: effective,
               effective_reason: reason,
               actor: :human,
               version: 7,
               harness_source: :session,
               support: %{sync: %{status: @sync_status, carrier: nil, reason: nil}, steer: steer, async: async_support}
             }
    end
  end

  test "default options do not authorize interrupt or install the pull tool" do
    for {requested, reason} <- [steer: :steer_not_wired, async: :pull_tool_unavailable] do
      assert %{effective: :sync, effective_reason: ^reason} = Effective.compute(record(requested), harness("codex"))
    end
  end

  test "wired native steer wins over interrupt and does not need acceptance" do
    harness = %{harness("kimi") | callbacks: %{steer: :native}}
    result = Effective.compute(record(:steer), harness, emulated_interrupt_accepted?: true)
    assert result.effective == :steer
    assert result.effective_reason == nil
    assert result.support.steer == %{status: :experimental, carrier: :native, reason: nil}
    assert Effective.compute(record(:steer), harness).support.steer == result.support.steer
  end

  test "no running entry yields nil with reason not_running for every requested mode" do
    for requested <- [:sync, :steer, :async] do
      result = Effective.compute(record(requested), nil)
      assert result.effective == nil
      assert result.effective_reason == :not_running
      assert result.harness_source == nil
      assert result.requested == requested
      assert result.version == 7
      assert result.actor == :human
      assert result.support == unknown_support(:not_running)
    end
  end

  test "unknown primitives yield unknown statuses and nil, never sync even with all options" do
    for source <- [:session, :dispatch], requested <- [:sync, :steer, :async] do
      harness = %{harness_id: "future", source: source, primitives: :unknown, callbacks: :unknown}
      result = Effective.compute(record(requested), harness, emulated_interrupt_accepted?: true, pull_tool_installed?: true)
      assert result.effective == nil
      assert result.effective_reason == :harness_unknown
      assert result.harness_source == source
      assert result.support == unknown_support(:harness_unknown)
    end
  end

  test "dispatch source names pending start only when there is no fallback reason" do
    harness = %{harness("codex") | source: :dispatch}
    assert %{effective: :sync, effective_reason: :pending_session_start, harness_source: :dispatch} = Effective.compute(record(:sync), harness)
    assert %{effective: :sync, effective_reason: :steer_not_wired} = Effective.compute(record(:steer), harness)
    assert %{effective_reason: nil} = Effective.compute(record(:sync), harness("codex"))
  end

  test "without a turn boundary fallback prefers async, then nil, and never invents steer" do
    for backend <- ["codex", "claude-repl"] do
      harness = harness(backend)
      harness = %{harness | primitives: %{harness.primitives | turn_boundary_start: false, pull_tool: true}}
      result = Effective.compute(record(:sync), harness, pull_tool_installed?: true, emulated_interrupt_accepted?: true)
      assert result.effective == :async
      assert result.effective_reason == :no_turn_boundary
      assert result.support.sync == %{status: :unsupported, carrier: nil, reason: :no_turn_boundary}
      assert %{effective: nil, effective_reason: :no_turn_boundary} = Effective.compute(record(:sync), harness, emulated_interrupt_accepted?: true)
    end
  end

  defp expected_support(interrupt, accepted, pull, installed) do
    steer =
      case {interrupt, accepted} do
        {:none, _} -> %{status: :unsupported, carrier: nil, reason: :no_interrupt}
        {_, false} -> %{status: :unsupported, carrier: nil, reason: :steer_not_wired}
        {_, true} -> %{status: :experimental, carrier: :emulated_interrupt, reason: nil}
      end

    async_support =
      if pull and installed,
        do: %{status: :proven, carrier: nil, reason: nil},
        else: %{status: :unsupported, carrier: nil, reason: :pull_tool_unavailable}

    {steer, async_support}
  end

  defp expected_effective(:sync, _steer, _async_support), do: {:sync, nil}
  defp expected_effective(:steer, %{status: :experimental}, _async_support), do: {:steer, nil}
  defp expected_effective(:steer, steer, _async_support), do: {:sync, steer.reason}
  defp expected_effective(:async, _steer, %{status: :proven}), do: {:async, nil}
  defp expected_effective(:async, _steer, _async_support), do: {:sync, :pull_tool_unavailable}

  defp record(requested), do: %{requested: requested, version: 7, actor: :human}

  defp harness(backend) do
    {:ok, primitives} = Capabilities.delivery_primitives(backend)
    %{harness_id: backend, source: :session, primitives: primitives, callbacks: Capabilities.callback_support(backend)}
  end

  defp unknown_support(reason) do
    Map.new([:steer, :sync, :async], &{&1, %{status: :unknown, carrier: nil, reason: reason}})
  end
end

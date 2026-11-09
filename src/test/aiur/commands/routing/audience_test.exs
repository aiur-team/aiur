Code.require_file("../../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.Routing.AudienceTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Commands.{HostApi, Routing, Scope}
  alias Aiur.Commands.Routing.Policy

  @config %{enabled: true, ack_ms: 300_000, answer_ms: 900_000, urgent_factor: 0.5}
  @secret String.duplicate("s", 64)

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    store = start_supervised_store!(dir)
    clock = start_supervised!(Supervisor.child_spec({Agent, fn -> DateTime.utc_now() end}, id: make_ref()))
    roster = start_supervised!(Supervisor.child_spec({Agent, fn -> :active end}, id: make_ref()))
    %{store: store, clock: clock, roster: roster}
  end

  defp router(ctx) do
    parent = self()

    opts = [
      name: nil,
      store: ctx.store,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      config: @config,
      alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
      roster_fun: fn _opts ->
        case Agent.get(ctx.roster, & &1) do
          :offline -> %{executors: []}
          state -> %{executors: [%{state: state}]}
        end
      end
    ]

    pid = start_supervised!(Supervisor.child_spec({Routing, opts}, id: make_ref(), restart: :temporary))
    :sys.get_state(pid)
    pid
  end

  defp command(ctx, payload) do
    {:ok, %{decision: decision}} = request(ctx.store, Map.merge(%{"question" => "Which index #{System.unique_integer([:positive])}?", "blocking" => false}, payload))
    decision
  end

  defp current(ctx, d) do
    {:ok, value} = DecisionStore.get(d.decision_id, ctx.store)
    value
  end

  defp creator_inbox(ctx) do
    {:ok, page} = HostApi.list(scope(), %{}, store: ctx.store)
    Enum.map(page["commands"], & &1["decision_id"])
  end

  defp needs_you(ctx) do
    {:ok, %{decisions: decisions}} = DecisionStore.retained_query(%{cursor: nil, lifecycle: nil, search: nil, ticket: nil, route: :needs_you}, ctx.store)
    Enum.map(decisions, & &1.decision_id)
  end

  defp advance(ctx, seconds), do: Agent.update(ctx.clock, &DateTime.add(&1, seconds, :second))
  defp tick(pid), do: GenServer.call(pid, :sweep)

  test "audience is validated, stored and survives a store restart", ctx do
    d = command(ctx, %{"audience" => "executor"})
    assert d.audience == :executor
    assert command(ctx, %{"audience" => "creator"}).audience == :creator

    assert {:error, {:decision_invalid, {:audience, :invalid_enum}}} = request(ctx.store, %{"question" => "x", "blocking" => false, "audience" => "everyone"})

    assert {:error, {:decision_invalid, {:audience, :conflicts_with_human_required}}} =
             request(ctx.store, %{"question" => "x", "blocking" => false, "audience" => "executor", "authority" => "human_required"})

    GenServer.stop(ctx.store)
    restored = start_supervised_store!(ctx.dir)
    assert current(%{ctx | store: restored}, d).audience == :executor
  end

  test "an Executor-only Command stays out of creator inboxes after every escalation deadline", ctx do
    executor_only = command(ctx, %{"audience" => "executor"})
    default = command(ctx, %{"question" => "Default routing?"})
    pid = router(ctx)

    assert current(ctx, executor_only).route_state == :with_executor
    advance(ctx, 3_600)
    tick(pid)

    # The default Command escalates at the deadline; the Executor-only one does not.
    assert current(ctx, default).route_state == :with_human
    assert current(ctx, executor_only).route_state == :with_executor
    assert current(ctx, executor_only).escalations == []
    refute Policy.needs_you?(current(ctx, executor_only))
    assert default.decision_id in needs_you(ctx)
    refute executor_only.decision_id in needs_you(ctx)
    assert default.decision_id in creator_inbox(ctx)
    refute executor_only.decision_id in creator_inbox(ctx)
    assert {:error, :not_found} = HostApi.show(scope(), executor_only.decision_id, store: ctx.store)
    refute_received {:alert, _topic, _opts}
  end

  test "with no live Executor an Executor-only Command waits and raises one operator alert", ctx do
    Agent.update(ctx.roster, fn _ -> :offline end)
    executor_only = command(ctx, %{"audience" => "executor"})
    pid = router(ctx)

    assert current(ctx, executor_only).route_state == :with_executor
    assert_received {:alert, "system.commands.executor_only_waiting", opts}
    assert opts[:needs_attention] == true
    assert opts[:message] =~ executor_only.decision_id

    advance(ctx, 3_600)
    tick(pid)
    refute_received {:alert, _topic, _opts}
    assert current(ctx, executor_only).route_state == :with_executor
    refute executor_only.decision_id in needs_you(ctx)
    refute executor_only.decision_id in creator_inbox(ctx)
  end

  test "a creator-addressed Command with default authority is in the creator inbox at once", ctx do
    creator = command(ctx, %{"audience" => "creator"})
    _pid = router(ctx)

    assert %{route_state: :with_both, human_visible_at: %DateTime{}} = current(ctx, creator)
    assert creator.decision_id in needs_you(ctx)
    assert creator.decision_id in creator_inbox(ctx)
  end

  defp scope do
    {:ok, %{scope: scope}} = Scope.mint("player-7", [@ticket.identifier], secret: @secret, now: DateTime.utc_now())
    scope
  end
end

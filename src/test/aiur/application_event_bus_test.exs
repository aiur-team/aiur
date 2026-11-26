defmodule Aiur.ApplicationEventBusTest do
  use ExUnit.Case, async: false

  alias Aiur.Application, as: AiurApp

  describe "event bus start order" do
    # Guards existing behaviour for C2–C6 moves; deliberately green on main.
    test "bus core precedes every Exchange subscriber in both run shapes" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true, recording?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false, recording?: true]
          ] do
        mods = modules(AiurApp.child_specs(opts))

        subscribers = [
          Aiur.DecisionStore,
          Aiur.Events.SubscriptionStoreSupervisor,
          Aiur.TicketActivity,
          Aiur.BuildOrder.TicketHistoryProvider,
          Aiur.DecisionMetrics,
          Aiur.Orchestrator,
          Aiur.ExecutorListener
        ]

        for child <- [Aiur.Events.IdGenerator, Aiur.Events.Exchange, Aiur.Events.Publisher] ++ subscribers do
          assert child in mods, "missing #{inspect(child)} for #{inspect(opts)}"
        end

        index = fn child -> Enum.find_index(mods, &(&1 == child)) end
        assert index.(Aiur.Events.IdGenerator) < index.(Aiur.Events.Exchange)
        assert index.(Aiur.Events.Exchange) < index.(Aiur.Events.Publisher)

        for subscriber <- subscribers do
          assert index.(Aiur.Events.Publisher) < index.(subscriber),
                 "Publisher must precede #{inspect(subscriber)} for #{inspect(opts)}"
        end

        for child <- [Aiur.Executor.Claims, Aiur.ExecutorWakeInbox] do
          assert child in mods
          assert index.(child) < index.(Aiur.ExecutorListener)
        end
      end
    end
  end

  defp modules(specs) do
    Enum.map(specs, fn
      mod when is_atom(mod) -> mod
      {mod, _opts} -> mod
      %{id: id} -> id
    end)
  end
end

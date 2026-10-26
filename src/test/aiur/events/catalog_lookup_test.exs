defmodule Aiur.Events.CatalogLookupTest do
  use ExUnit.Case, async: false

  alias Aiur.Events
  alias Aiur.Events.Catalog
  alias Aiur.Events.Catalog.{Entries, Entry, SystemEntries}

  @runtime_work [{Entry, :alert, 3}, {SystemEntries, :entries, 0}, {Events, :specificity_score, 1}]

  test "registry reads and lookup reuse constructed entries and precomputed specificity" do
    Code.ensure_loaded!(Catalog)

    for {module, _, _} = pattern <- @runtime_work do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(pattern, true, [:local]) == 1
    end

    caller = self()

    worker =
      spawn(fn ->
        receive do
          :lookup ->
            results = Enum.map(["ticket.42.agent.decision.answered", "foo.bar"], &Catalog.lookup/1)
            send(caller, {:lookups, self(), results, Entries.entries()})

            receive do
              :stop -> :ok
            after
              5_000 -> :ok
            end
        after
          5_000 -> :ok
        end
      end)

    on_exit(fn ->
      for pattern <- @runtime_work, do: :erlang.trace_pattern(pattern, false, [:local])
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    :erlang.trace(worker, true, [:call])
    send(worker, :lookup)

    assert_receive {:lookups, ^worker, [%Entry{pattern: "ticket.*.agent.decision.#"}, %Entry{owner: "unknown"}], entries}, 5_000
    assert entries == Catalog.entries()
    assert Enum.any?(entries, &(&1.pattern == "ticket.*.ci.passed"))

    delivered = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^delivered}, 5_000
    refute_receive {:trace, ^worker, :call, _}, 0
    send(worker, :stop)
  end
end

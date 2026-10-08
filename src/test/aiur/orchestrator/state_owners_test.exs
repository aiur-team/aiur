Code.require_file("../../support/state_write_scan.exs", __DIR__)

defmodule Aiur.Orchestrator.StateOwnersTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.State.Owners
  alias Aiur.StateWriteScan

  @owner_ids [:core, :dispatch, :lifecycle, :control, :pr_lifecycle, :messaging, :accounting, :github_listeners]
  @fields Map.keys(%State{}) -- [:__struct__]
  @lib Path.expand("../../../lib", __DIR__)
  @allowlist_path Path.expand("../../support/state_writers_allowlist.exs", __DIR__)

  test "every State field has exactly one owner" do
    owned_fields = Enum.flat_map(@owner_ids, &Owners.fields_of/1)

    assert Enum.sort(owned_fields) == Enum.sort(@fields),
           "unowned fields: #{inspect(@fields -- owned_fields)}; stale fields: #{inspect(owned_fields -- @fields)}"

    assert length(owned_fields) == length(Enum.uniq(owned_fields))
    assert Enum.all?(@fields, &(Owners.owner(&1) in @owner_ids))
  end

  test "no unlisted module writes a field it does not own" do
    writes = production_writes()
    {allowlist, _binding} = Code.eval_file(@allowlist_path)
    allowed = MapSet.new(allowlist, fn {module, field, _reason} -> {module, field} end)
    foreign = MapSet.reject(writes, fn {module, field} -> owner_member?(module, Owners.owner(field)) end)
    assert MapSet.difference(foreign, allowed) == MapSet.new()
    assert MapSet.difference(allowed, foreign) == MapSet.new(), "remove stale allowlist rows"
    assert length(allowlist) == MapSet.size(allowed), "remove duplicate allowlist rows"
    assert Enum.all?(allowlist, fn {_, _, reason} -> is_binary(reason) and String.trim(reason) != "" end)
  end

  test "the umbrella orchestrator does not authorize foreign child writers" do
    writes = StateWriteScan.scan_source("defmodule Aiur.Orchestrator.NewWriter do; def change(state), do: %{state | poll_frozen: true}; end", @fields)
    foreign = MapSet.reject(writes, fn {module, field} -> owner_member?(module, Owners.owner(field)) end)
    assert foreign == MapSet.new([{Aiur.Orchestrator.NewWriter, :poll_frozen}])
    assert owner_member?(Aiur.Orchestrator, :core)
  end

  test "regression guard: the build queue writes no State field (RC-20)" do
    build_queue_writes =
      @lib
      |> Path.join("aiur/build_queue/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&scan_file/1)

    assert build_queue_writes == []
  end

  test "scanner catches multiline updates, alternate State variables and nested writes" do
    source = """
    defmodule ForeignWriter do
      alias Aiur.Orchestrator.State
      def change(%State{} = before_cycle) do
        after_cycle = %{before_cycle |
          running: %{},
          claimed: MapSet.new()
        }
        Map.put(after_cycle, :completed, MapSet.new())
        after_cycle |> Map.put(:retry_attempts, %{})
        put_in(after_cycle.ci_lifecycle.poll_cache, %{})
        update_in(after_cycle.queue_store, & &1)
        put_in(after_cycle, [:global_pause, :source], "operator")
        update_in(after_cycle[:running], & &1)
        %State{after_cycle | dispatch_selection_hold: nil}
      end
    end
    """

    expected = [:running, :claimed, :completed, :retry_attempts, :ci_lifecycle, :queue_store, :global_pause, :dispatch_selection_hold]
    assert StateWriteScan.scan_source(source, @fields) == MapSet.new(expected, &{ForeignWriter, &1})
  end

  test "scanner ignores reads, declarations, comments and quoted text" do
    source = ~S'''
    defmodule Reader do
      alias Aiur.Orchestrator.State
      @example "%{state | running: %{}}"
      # Map.put(state, :claimed, value)
      def read(%State{running: running} = state), do: {running, state.completed}
    end
    '''

    assert StateWriteScan.scan_source(source, @fields) == MapSet.new()
  end

  defp production_writes do
    @lib |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.flat_map(&scan_file/1) |> MapSet.new()
  end

  defp scan_file(path), do: path |> File.read!() |> StateWriteScan.scan_source(@fields) |> MapSet.to_list()

  defp owner_member?(module, owner) do
    Enum.any?(Owners.members_of(owner), fn member ->
      module == member or
        (member != Aiur.Orchestrator and String.starts_with?(Atom.to_string(module), Atom.to_string(member) <> "."))
    end)
  end
end

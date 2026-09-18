defmodule Aiur.Orchestrator.ResumeDeclineReasonTest do
  # #2699: `aiur resume` crashed with a FunctionClauseError because the resume
  # path translated dispatch decline reasons with a partial function that had
  # no clause for `:blocked_on_decision`. These cases pin the translation as
  # total over the reasons the dispatch policy can produce.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchPolicy, PauseResume, State}

  @issue %Issue{id: "52", identifier: "52", title: "Blocked", state: "In Progress", labels: ["agent:in-progress"]}

  defp translate(reason, state \\ %State{}, opts \\ [decision_lookup: fn _ids -> {:ok, []} end]),
    do: PauseResume.resume_decline_reason(reason, @issue, state, opts)

  test "every dispatch decline reason has its own resume refusal" do
    reasons = DispatchPolicy.dispatch_decline_reasons()

    assert length(reasons) == length(Enum.uniq(reasons))

    for reason <- reasons do
      translated = translate(reason)

      refute match?({:unmapped_dispatch_decline, _}, translated),
             "dispatch decline reason #{inspect(reason)} has no resume translation in PauseResume.resume_decline_reason/4"
    end
  end

  test "the decline reason list matches the dispatch_decline_reason typespec" do
    {:ok, types} = Code.Typespec.fetch_types(DispatchPolicy)

    {_kind, {:dispatch_decline_reason, union, []}} =
      Enum.find(types, fn {_kind, {name, _type, _args}} -> name == :dispatch_decline_reason end)

    assert MapSet.new(union_atoms(union)) == MapSet.new(DispatchPolicy.dispatch_decline_reasons())
  end

  test "every decline reason literal in the dispatch policy source is in the list" do
    source = File.read!(Path.expand("../../../lib/aiur/orchestrator/dispatch_policy.ex", __DIR__))

    literals =
      ~r/\{:skip, :([a-z_]+)\}/
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_existing_atom/1)
      |> MapSet.new()

    assert MapSet.size(literals) > 0
    assert MapSet.subset?(literals, MapSet.new(DispatchPolicy.dispatch_decline_reasons()))
  end

  test "blocked_on_decision names the open blocking decision" do
    parent = self()

    lookup = fn ticket_ids ->
      send(parent, {:looked_up, ticket_ids})
      {:ok, ["dec-7"]}
    end

    assert translate(:blocked_on_decision, %State{blocked_ticket_ids: MapSet.new(["52"])}, decision_lookup: lookup) ==
             {:blocked_on_decision, %{decision_ids: ["dec-7"], store: :available}}

    assert_received {:looked_up, ["52"]}
  end

  test "blocked_on_decision says when the decision store could not be read" do
    assert translate(:blocked_on_decision, %State{blocked_ticket_ids: :unavailable}) ==
             {:blocked_on_decision, %{decision_ids: [], store: :unavailable}}

    assert translate(:blocked_on_decision, %State{}, decision_lookup: fn _ids -> {:error, :store_unavailable} end) ==
             {:blocked_on_decision, %{decision_ids: [], store: :unavailable}}
  end

  test "parked tickets get a named refusal" do
    assert translate(:parked) == :ticket_parked
  end

  test "an unknown decline reason is a named refusal, not a crash" do
    log =
      capture_log(fn ->
        assert translate(:reason_added_later) == {:unmapped_dispatch_decline, :reason_added_later}
      end)

    assert log =~ "untranslated dispatch reason"
  end

  defp union_atoms({:type, _line, :union, members}), do: Enum.flat_map(members, &union_atoms/1)
  defp union_atoms({:atom, _line, atom}), do: [atom]
end

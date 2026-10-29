defmodule Aiur.TestSupport.StreamdeckBuildFixture do
  @moduledoc false
  alias Aiur.BuildOrder.Metadata

  # Existing surface scenarios vary their retained fleet fixture. Mirror those
  # facts into a Build window so they exercise the authoritative Ticket path.
  def window(snapshot) do
    rows =
      [:agents, :running, :retrying, :idle]
      |> Enum.flat_map(fn source -> Enum.map(Map.get(snapshot, source, []), &{&1, source}) end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{agent, source}, position} -> row(agent, position, source) end)

    {plan, now} = Enum.split_with(rows, &(&1.sec == "plan"))
    {:ok, %{sources: %{agents: %{state: "ok", observed_at: System.system_time(:millisecond)}}, sections: %{now: now, plan: plan, nq: []}}}
  end

  defp row(agent, position, source) do
    state = state(agent, source)
    number = Regex.run(~r/(\d+)$/, agent.identifier, capture: :all_but_first)
    num = if number, do: number |> hd() |> String.to_integer(), else: position

    %{
      id: agent.identifier,
      num: num,
      title: agent[:title],
      sec: if(state == "queued", do: "plan", else: "now"),
      qpos: position,
      pct: agent[:progress_percent],
      priority: agent[:priority],
      lane: Metadata.parse(agent[:labels] || []).lane,
      progress_freshness: agent[:progress_freshness],
      dependency_ready: if(agent[:waiting_reason] == :waiting_for_dependency, do: false, else: agent[:blocked_by] == []),
      agent: %{state: state, model: agent[:backend], name: nil}
    }
  end

  defp state(%{open_decision_count: count}, _source) when count > 0, do: "command"
  defp state(%{work_state: :paused}, _source), do: "paused"
  defp state(%{work_state: :error}, _source), do: "error"
  defp state(%{waiting_reason: :waiting_for_dependency}, _source), do: "queued"
  defp state(_agent, :idle), do: "queued"
  defp state(_agent, :retrying), do: "retrying"
  defp state(_agent, _source), do: "active"
end

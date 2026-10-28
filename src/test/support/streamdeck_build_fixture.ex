defmodule Aiur.TestSupport.StreamdeckBuildFixture do
  @moduledoc false

  # Existing surface scenarios vary their retained fleet fixture. Mirror those
  # facts into a Build window so they exercise the authoritative Ticket path.
  def window(snapshot) do
    rows =
      (Map.get(snapshot, :agents, []) ++ Map.get(snapshot, :running, []) ++ Map.get(snapshot, :retrying, []) ++ Map.get(snapshot, :idle, []))
      |> Enum.with_index(1)
      |> Enum.map(fn {agent, position} -> row(agent, position) end)

    {plan, now} = Enum.split_with(rows, &(&1.sec == "plan"))
    {:ok, %{sources: %{agents: %{state: "ok", observed_at: System.system_time(:millisecond)}}, sections: %{now: now, plan: plan, nq: []}}}
  end

  defp row(agent, position) do
    state = state(agent)
    number = Regex.run(~r/(\d+)$/, agent.identifier, capture: :all_but_first)
    num = if number, do: number |> hd() |> String.to_integer(), else: position

    %{
      id: agent.identifier,
      num: num,
      title: agent[:title],
      sec: if(state == "queued", do: "plan", else: "now"),
      qpos: position,
      pct: agent[:progress_percent],
      agent: %{state: state, model: agent[:backend], name: nil}
    }
  end

  defp state(%{open_decision_count: count}) when count > 0, do: "command"
  defp state(%{work_state: :paused}), do: "paused"
  defp state(%{work_state: :error}), do: "error"
  defp state(%{waiting_reason: :waiting_for_dependency}), do: "queued"
  defp state(_agent), do: "active"
end

defmodule Aiur.Executor.SessionCLI do
  @moduledoc false
  alias Aiur.Executor.Status
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  @spec rpc(keyword()) :: :ok
  def rpc(opts), do: guarded("executor-session", fn -> opts |> run() |> exit_marker() end)

  @spec run(keyword()) :: 0
  def run(opts \\ []) do
    snapshot = Status.snapshot(opts)
    status = Map.merge(binding_fields(snapshot.binding), snapshot)
    IO.puts(if Keyword.get(opts, :json, false), do: encode(status), else: render(status))
    0
  end

  @spec print_status(map()) :: :ok
  def print_status(snapshot), do: IO.puts(status_line(snapshot))

  defp status_line(%{attached: false}), do: "EXECUTOR not attached (aiur executor-attach --harness claude|codex)"
  defp status_line(%{attached: :unavailable}), do: "EXECUTOR attachment unavailable"

  defp status_line(%{attached: true} = snapshot) do
    "EXECUTOR attached=yes state=#{field(snapshot.harness_state, :state)} age=#{age_label(snapshot.harness_state)} " <>
      "read=#{field(snapshot.read_capability, :status)} blockers=#{blocker_count(snapshot.blockers)}"
  end

  defp field(:unavailable, _key), do: :unavailable
  defp field(data, key), do: Map.fetch!(data, key)
  defp age_label(%{age_ms: age}) when is_integer(age), do: "#{div(age, 1_000)}s"
  defp age_label(:unavailable), do: "unavailable"
  defp age_label(_), do: "unknown"

  defp blocker_count(%{items: items, sources: %{commands: :ok, asks: :ok, fleet: :ok}}), do: length(items)
  defp blocker_count(_), do: :unavailable

  defp binding_fields(:unavailable), do: %{state: "unavailable", live?: :unavailable, age_ms: nil, freshness: "unknown"}
  defp binding_fields(nil), do: %{state: "detached", live?: false, age_ms: nil, freshness: "unknown"}
  defp binding_fields(binding), do: binding

  defp encode(status) do
    status
    |> Map.update!(:background_agents, &background_json/1)
    |> Map.update!(:blockers, &blockers_json/1)
    |> Jason.encode!()
  end

  defp background_json({:ok, rows}), do: %{status: :ok, agents: rows}
  defp background_json({:unsupported, reason}), do: %{status: :unsupported, reason: reason}
  defp background_json(:unavailable), do: :unavailable

  defp blockers_json(:unavailable), do: :unavailable
  defp blockers_json(blockers), do: Map.update!(blockers, :sources, &Map.new(&1, fn {source, value} -> {source, source_json(value)} end))

  defp source_json(:ok), do: %{status: :ok}
  defp source_json({:unavailable, reason}) when is_atom(reason), do: %{status: :unavailable, reason: reason}
  defp source_json({:unavailable, _reason}), do: %{status: :unavailable, reason: :unknown}

  defp render(status) do
    "#{String.upcase(status.state)} binding=#{Map.get(status, :binding_id, "-")} harness=#{Map.get(status, :harness, "-")} live=#{status.live?}\n" <>
      "observed_at=#{DateTime.to_iso8601(status.observed_at)} age_ms=#{status.age_ms || "unknown"} freshness=#{status.freshness}\n" <>
      "recording=#{status.recording?} foreign_session=#{status.foreign_session_count || "unknown"} not_attached=#{status.not_attached_count || "unknown"}\n" <>
      "transcript_rejection=#{status.transcript_rejection || "none"}\n" <>
      "harness_session=#{Jason.encode!(status.harness_session)}"
  end
end

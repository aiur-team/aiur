defmodule Aiur.Project.StatusRows do
  @moduledoc """
  The `projects` list of `aiur status --json`: one row per running or failed
  project. `running` is the agent count from that project's snapshot, and `null`
  (never `0`) when the project is not running or its snapshot is unavailable.
  """

  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Project
  alias Aiur.Project.{Context, Supervisors}

  @read_timeout_ms 1_500

  @spec print() :: :ok
  def print do
    IO.puts(Jason.encode!(%{observed_at: DateTime.to_iso8601(DateTime.utc_now()), projects: rows()}))
  end

  @spec rows() :: [map()]
  def rows do
    if Process.whereis(Supervisors), do: Enum.map(Supervisors.which_projects(), &row/1), else: []
  end

  defp row(%{id: id, repo: repo, state: :running}) do
    base = %{id: id, repo: repo, state: "running"}

    case read_snapshot(id) do
      {freshness, snapshot, metadata} when freshness in [:current, :stale] ->
        Map.merge(base, %{running: length(Map.get(snapshot, :running, [])), observed_at: metadata.observed_at, age_ms: metadata.age_ms, freshness: to_string(freshness)})

      _unavailable ->
        Map.merge(base, unavailable())
    end
  end

  defp row(%{id: id, repo: repo, state: state}), do: Map.merge(%{id: id, repo: repo, state: to_string(state)}, unavailable())

  defp unavailable, do: %{running: nil, observed_at: nil, age_ms: nil, freshness: "unavailable"}

  # The store answers from the reader's process, so the read runs inside the project.
  defp read_snapshot(id) do
    case Project.Registry.project(id) do
      nil ->
        :orchestrator_unavailable

      project ->
        Task.async(fn ->
          Context.put(project)
          SnapshotStore.read(Project.name(Aiur.Orchestrator, id), @read_timeout_ms)
        end)
        |> Task.await(@read_timeout_ms * 2)
    end
  end
end

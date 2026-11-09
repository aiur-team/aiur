defmodule Aiur.Handoff.All do
  @moduledoc """
  Prepares a keep-agents handoff for every project of a gateway, each inside its own project
  context so it snapshots its own orchestrator, writes its own record and judges its own config
  fingerprint. A project that fails to prepare falls back alone: its agents restart from their
  workspaces while the other projects' agents are still handed off.
  """
  alias Aiur.Project

  # Prepare's own budget is 100 s; the shell RPC envelope is 120 s, so projects prepare in parallel.
  @task_timeout_ms 110_000

  @spec prepare_all(keyword()) :: {:ok, %{projects: map(), handoff_ids: [String.t()]}} | {:error, :no_projects}
  def prepare_all(opts \\ []) do
    case Project.Supervisors.which_projects() do
      [] ->
        {:error, :no_projects}

      projects ->
        results =
          projects
          |> Enum.filter(&(&1.state == :running))
          |> Task.async_stream(&prepare_one(&1.id, opts), timeout: @task_timeout_ms, max_concurrency: 4, on_timeout: :kill_task, ordered: true)
          |> Enum.zip_with(Enum.filter(projects, &(&1.state == :running)), fn
            {:ok, result}, %{id: id} -> {id, result}
            {:exit, reason}, %{id: id} -> {id, {:error, {:prepare_exit, reason}}}
          end)
          |> Map.new()

        {:ok, %{projects: results, handoff_ids: for({_id, {:ok, %{handoff_id: id}}} <- results, do: id)}}
    end
  end

  defp prepare_one(id, opts) do
    Project.Context.put(Project.Registry.project(id))
    Aiur.Handoff.prepare(Keyword.delete(opts, :orchestrator))
  end
end

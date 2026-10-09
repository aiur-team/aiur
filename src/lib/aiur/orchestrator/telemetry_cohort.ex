defmodule Aiur.Orchestrator.TelemetryCohort do
  @moduledoc "Bounded attempt cohort attributes resolved from the dispatched issue."
  alias Aiur.BuildOrder.Features
  alias Aiur.{CodingAgent, Config}
  alias Aiur.RunTelemetry.Lifecycle

  @spec record_dispatch(Aiur.Issue.t(), String.t(), map()) :: :ok
  def record_dispatch(issue, attempt_id, metadata) do
    Lifecycle.record(issue.identifier, attempt_id, :dispatch, :point, Map.merge(attempt_fields(issue), metadata))
  end

  @spec attempt_fields(Aiur.Issue.t(), keyword()) :: map()
  def attempt_fields(issue, opts \\ []) do
    owner = owner(issue.identifier, opts)
    prefixes = prefixes()

    %{
      backend: CodingAgent.backend_for(issue),
      model: CodingAgent.model_for(issue),
      effort: CodingAgent.effort_for(issue),
      feature: owner[:feature],
      epic: owner[:epic],
      tags: Enum.filter(issue.labels || [], &String.starts_with?(&1, prefixes)),
      blockers: Enum.map(issue.blocked_by || [], &blocker/1),
      start_mode: "normal"
    }
  end

  defp prefixes do
    case Config.settings() do
      {:ok, settings} -> Map.get(settings.observability, :capture_label_prefixes, ["experiment:", "cohort:", "feature:"])
      {:error, _} -> ["experiment:", "cohort:", "feature:"]
    end
  end

  defp blocker(value) when is_map(value), do: Map.get(value, :identifier) || Map.get(value, "identifier") || Map.get(value, :id) || Map.get(value, "id")
  defp blocker(value), do: value

  defp owner(identifier, opts) when is_binary(identifier) do
    with {number, ""} <- Integer.parse(identifier),
         {:ok, owner} <- Features.owner(number, Keyword.put_new(opts, :timeout, 100)) do
      owner
    else
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  defp owner(_, _), do: %{}
end

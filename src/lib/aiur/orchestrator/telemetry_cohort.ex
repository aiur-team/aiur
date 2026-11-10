defmodule Aiur.Orchestrator.TelemetryCohort do
  @moduledoc "Bounded attempt cohort attributes resolved from the dispatched issue."
  alias Aiur.BuildOrder.Features
  alias Aiur.{CodingAgent, Config}
  alias Aiur.RunTelemetry
  alias Aiur.Signal

  @spec record_dispatch(Aiur.Issue.t(), String.t(), map()) :: :ok
  def record_dispatch(issue, attempt_id, metadata) do
    # `account` and `priority` let `aiur capacity report` join samples and split windows.
    fields =
      Map.merge(attempt_fields(issue), %{
        account: issue.selected_account,
        priority: priority(),
        reason: dispatch_reason(issue),
        candidates: get_in(issue.dispatch_selection || %{}, [:candidates])
      })

    Signal.lifecycle(issue.identifier, attempt_id, :dispatch, :point, Map.merge(fields, metadata))
  end

  defp priority do
    Enum.join(Config.agent_priority(), ",")
  rescue
    _error -> nil
  end

  @doc "Why the capacity policy chose this dispatch (`dispatch_selection.chosen.reason`), or `nil` (#7889)."
  @spec dispatch_reason(Aiur.Issue.t()) :: atom() | nil
  def dispatch_reason(%Aiur.Issue{dispatch_selection: %{chosen: %{reason: reason}}}), do: reason
  def dispatch_reason(_issue), do: nil

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
      tags: Enum.filter(issue.labels, &String.starts_with?(&1, prefixes)),
      work_kind: work_kind(issue.labels, issue.title),
      blockers: Enum.map(issue.blocked_by, &blocker/1),
      start_mode: "normal"
    }
  end

  @doc "The issue's first `feature:<slug>` label in sorted order, else `:none`."
  @spec feature_slug(Aiur.Issue.t()) :: String.t() | :none
  def feature_slug(%Aiur.Issue{} = issue) do
    issue
    |> Aiur.Issue.label_names()
    |> Enum.sort()
    |> Enum.find_value(:none, fn label ->
      case Features.parse_label(label) do
        {:ok, slug} -> slug
        :ignore -> nil
      end
    end)
  end

  defp prefixes do
    case Config.settings() do
      {:ok, settings} -> Map.get(settings.observability, :capture_label_prefixes, ["experiment:", "cohort:", "feature:"])
      {:error, _} -> ["experiment:", "cohort:", "feature:"]
    end
  end

  defp work_kind(labels, title), do: RunTelemetry.work_kind(labels, title)

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

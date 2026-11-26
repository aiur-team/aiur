defmodule Aiur.BuildOrder.HistoryBackfill do
  @moduledoc "Durable, capped allocation of local unsorted history to a backfill ticket."
  alias Aiur.BuildOrder.{EpicOverrides, Features}
  alias Aiur.BuildOrder.History.Export
  alias Aiur.BuildOrder.HistoryBackfill.Checkpoint
  alias Aiur.Issue

  # Measured 100-ticket pilot: #3180 / #6617, docs/measurements/2026-10-25-history-classification-cost.md.
  @max_tickets_per_run 100

  @spec tool_call(Issue.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def tool_call(issue, args, opts \\ []) do
    with true <- "history-backfill" in Issue.label_names(issue),
         {:ok, number} <- number(issue.identifier) do
      next_page(number, args.limit, args.start_after, opts)
    else
      false -> {:error, :not_a_history_backfill_ticket}
      error -> error
    end
  end

  defp number(identifier) when is_binary(identifier) do
    if Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, identifier), do: {:ok, String.to_integer(identifier)}, else: {:error, :history_export_needs_github_issue}
  end

  defp number(_), do: {:error, :history_export_needs_github_issue}

  @spec next_page(pos_integer(), pos_integer(), non_neg_integer() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def next_page(issue, limit, start_after, opts) do
    repository = Keyword.get_lazy(opts, :repository, &Aiur.Tracker.project_identity/0)
    opts = Keyword.put_new(opts, :cap, @max_tickets_per_run)

    if is_binary(repository) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repository) do
      :global.trans({{__MODULE__, repository, issue}, self()}, fn -> allocate(issue, limit, start_after, repository, opts) end, [node()])
    else
      {:error, :history_export_needs_github_issue}
    end
  end

  defp allocate(issue, limit, start_after, repository, opts) do
    with {:ok, checkpoint, path} <- Checkpoint.load(issue, repository, start_after, opts),
         {:ok, epics} <- catalog(opts),
         {:ok, features} <- features(opts),
         {:ok, page, next} <- page(checkpoint, limit, path, opts) do
      result = Map.merge(page, Map.take(next, [:issue, :cap, :handed_out, :cursor]))
      {:ok, Map.merge(result, %{ok: true, remaining: next.cap - next.handed_out, cap_reached: next.cap == next.handed_out, epics: epics, features: features})}
    end
  end

  defp catalog(opts) do
    case Keyword.get(opts, :catalog, &EpicOverrides.catalog/0).() do
      {:ok, epics} -> {:ok, Enum.map(epics, & &1.key)}
      _ -> {:error, :epic_catalog_unavailable}
    end
  end

  defp features(opts) do
    case Keyword.get(opts, :features, &Features.snapshot/0).() do
      {:ok, %{features: features}} -> {:ok, features |> Map.values() |> Enum.sort_by(& &1.slug) |> Enum.map(&%{slug: &1.slug, label: &1.label, epics: Enum.map(&1.epics, fn epic -> epic.key end)})}
      _ -> {:error, :feature_registry_unavailable}
    end
  end

  defp page(%{handed_out: cap, cap: cap} = checkpoint, _limit, _path, _opts), do: {:ok, %{rows: [], exhausted: nil}, checkpoint}

  defp page(checkpoint, limit, path, opts) do
    export = Keyword.get(opts, :export, &Export.page/1)

    case export.(unsorted: true, after: checkpoint.cursor, limit: min(limit, checkpoint.cap - checkpoint.handed_out)) do
      {:ok, page} -> commit_page(page, checkpoint, path, opts)
      {:error, message} -> {:error, {:history_unavailable, message}}
    end
  end

  defp commit_page(page, checkpoint, path, opts) do
    rows = page.tickets

    cursor =
      case List.last(rows) do
        nil -> checkpoint.cursor
        row -> row.number
      end

    next = %{checkpoint | handed_out: checkpoint.handed_out + length(rows), cursor: cursor}

    with :ok <- Checkpoint.save(path, next, opts) do
      result = %{rows: rows, history: page.sources.history, matching_total: page.matching_total, unresolved_total: page.unresolved_total, exhausted: exhausted(page)}
      {:ok, result, next}
    end
  end

  defp exhausted(%{sources: %{history: %{freshness: freshness}}}) when freshness not in ["current", :current], do: nil
  defp exhausted(page), do: page.tickets == [] and page.unresolved_total == 0
end

defmodule Aiur.Orchestrator.InstanceHeartbeatMetadata.ProjectSignals do
  @moduledoc """
  Per-project queue entry and pending Decision count for the instance heartbeat.

  Each reader returns a map keyed by lower-cased `owner/name`, or `nil` when its store cannot be read.
  A `nil` source omits that field from every project, so the summary reports `unknown`, never `0`.
  """

  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Instance.LeaseStore.TicketKey

  @ready_states [:ready, :promoted, :overridden]

  @doc "Pending Decision count per repo, from the retained `needs_you_by_ticket` counts."
  @spec pending_decisions(keyword()) :: %{String.t() => non_neg_integer()} | nil
  def pending_decisions(opts \\ []) do
    case contained(Keyword.get(opts, :counts_fun, &Aiur.Commands.query_counts/0)) do
      {:ok, %{needs_you_by_ticket: by_ticket}} when is_map(by_ticket) -> group(by_ticket)
      _ -> nil
    end
  end

  # One unparseable ticket key could belong to any repo, so the whole source is unknown.
  defp group(by_ticket) do
    Enum.reduce_while(by_ticket, %{}, fn {ticket, count}, acc ->
      case repo_of(ticket) do
        nil -> {:halt, nil}
        repo -> {:cont, Map.update(acc, repo, count, &(&1 + count))}
      end
    end)
  end

  @doc """
  The first startable queue item, per repo. The build queue serves the single configured tracker repo,
  so only that repo is readable; its value is `nil` when the queue is readable but nothing is ready.
  """
  @spec next_queue(keyword()) :: %{String.t() => pos_integer() | nil} | nil
  def next_queue(opts \\ []) do
    repo = Keyword.get(opts, :repo_fun, &GitHubConfig.repo/0) |> contained()
    model = contained(Keyword.get(opts, :queue_fun, &Aiur.BuildQueue.show/0))

    with repo when is_binary(repo) <- repo,
         %{queues: queues, status: :running} <- model do
      first =
        queues
        |> Enum.sort_by(&{&1.set_rank, &1.queue_id})
        |> Enum.find_value(fn q -> Enum.find(q.items, &(&1.state in @ready_states and &1.verdict == :ready)) end)

      %{String.downcase(repo) => first && first.number}
    else
      _ -> nil
    end
  end

  defp repo_of(ticket) do
    case TicketKey.ticket_key(ticket) do
      {:ok, key} -> key |> String.split("#") |> hd() |> String.downcase()
      _ -> nil
    end
  end

  defp contained(fun) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      other -> other
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end

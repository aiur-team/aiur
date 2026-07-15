defmodule Aiur.BuildOrder.TicketDetail.DestinationNormalizer do
  @moduledoc false

  alias Aiur.BuildOrder.Bounded
  alias Aiur.BuildOrder.TicketDetail.{Destinations, Failure, IssueDestination, PullRequestDestination}
  alias Aiur.TrackerIdentity

  @max_pull_requests 20

  @spec max_pull_requests() :: pos_integer()
  def max_pull_requests, do: @max_pull_requests

  @spec normalize(String.t(), TrackerIdentity.t(), map()) ::
          {:ok, Destinations.t()} | {:error, Failure.t()}
  def normalize(issue_url, %TrackerIdentity{} = identity, relationship_data)
      when is_map(relationship_data) do
    with {:ok, issue_url} <- Bounded.github_issue_url_for(issue_url, identity),
         {:ok, nodes, truncated?} <- relationship_nodes(relationship_data),
         {:ok, pull_requests} <- pull_requests(nodes, identity),
         true <- unique_pull_requests?(pull_requests) do
      pull_requests = Enum.sort_by(pull_requests, &priority_key/1)

      {:ok,
       %Destinations{
         issue: %IssueDestination{url: issue_url},
         pull_requests: pull_requests,
         primary_pull_request: List.first(pull_requests) || :not_linked,
         pull_requests_truncated?: truncated?
       }}
    else
      _ -> {:error, %Failure{kind: :validation}}
    end
  end

  def normalize(_issue_url, _identity, _relationship_data),
    do: {:error, %Failure{kind: :schema}}

  defp relationship_nodes(%{nodes: nodes, truncated?: truncated?})
       when is_list(nodes) and length(nodes) <= @max_pull_requests and is_boolean(truncated?),
       do: {:ok, nodes, truncated?}

  defp relationship_nodes(_relationship_data), do: :error

  defp pull_requests(nodes, identity) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case pull_request(node, identity) do
        {:ok, destination} -> {:cont, {:ok, [destination | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, destinations} -> {:ok, Enum.reverse(destinations)}
      :error -> :error
    end
  end

  defp pull_request(
         %{
           number: number,
           url: url,
           state: state,
           draft?: draft?,
           updated_at: updated_at
         },
         identity
       )
       when is_integer(number) and number > 0 and is_boolean(draft?) do
    with {:ok, url} <- Bounded.github_pull_request_url_for(url, identity, number),
         {:ok, state} <- state(state),
         {:ok, updated_at} <- timestamp(updated_at) do
      {:ok,
       %PullRequestDestination{
         number: number,
         url: url,
         state: state,
         draft?: draft?,
         updated_at: updated_at
       }}
    else
      _ -> :error
    end
  end

  defp pull_request(_node, _identity), do: :error

  defp state("OPEN"), do: {:ok, :open}
  defp state("CLOSED"), do: {:ok, :closed}
  defp state("MERGED"), do: {:ok, :merged}
  defp state(_state), do: :error

  defp timestamp(%DateTime{} = timestamp), do: {:ok, timestamp}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp timestamp(_value), do: :error

  defp unique_pull_requests?(pull_requests) do
    numbers = Enum.map(pull_requests, & &1.number)
    urls = Enum.map(pull_requests, & &1.url)
    Enum.uniq(numbers) == numbers and Enum.uniq(urls) == urls
  end

  defp priority_key(%PullRequestDestination{} = destination) do
    active_rank = if destination.state == :open, do: 0, else: 1
    draft_rank = if destination.state == :open and not destination.draft?, do: 1, else: 0
    unix_timestamp = DateTime.to_unix(destination.updated_at, :microsecond)

    {active_rank, draft_rank, -unix_timestamp, -destination.number}
  end
end

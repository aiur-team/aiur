defmodule Aiur.LandingWatch.MergeGroupRequeue do
  @moduledoc "Safely requeues approved PRs after non-PR merge-group failures."
  alias Aiur.GitHub.{Client, Transport}
  alias Aiur.LandingWatch.{Attribution, Journal, Observer}
  alias Aiur.PrMerge.Queue

  @spec requeue_group_prs([pos_integer()], [map()], map(), String.t(), keyword()) :: :ok | {:error, term()}
  def requeue_group_prs(numbers, observations, run, reason, opts) do
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    identity = "merge-group-requeue-#{run["id"]}"

    Enum.reduce_while(numbers, :ok, fn number, result ->
      requeue_number(number, result, observations, run, reason, identity, now, opts)
    end)
  end

  defp requeue_number(
         _number,
         {:error, _} = error,
         _observations,
         _run,
         _reason,
         _identity,
         _now,
         _opts
       ),
       do: {:halt, error}

  defp requeue_number(number, :ok, observations, run, reason, identity, now, opts) do
    case Enum.find(observations, &(&1.number == number)) do
      nil -> {:cont, :ok}
      pr -> requeue_observed_pr(pr, number, run, reason, identity, now, opts)
    end
  end

  defp requeue_observed_pr(pr, number, run, reason, identity, now, opts) do
    if eligible_for_group_requeue?(pr, opts) do
      reserve_and_enqueue(pr, number, run, reason, identity, now, opts)
    else
      {:cont, :ok}
    end
  end

  defp reserve_and_enqueue(pr, number, run, reason, identity, now, opts) do
    case Journal.claim_alert(number, pr.head, identity, opts) do
      {:ok, :already_claimed} -> {:cont, :ok}
      {:ok, :new} -> requeue_claimed_pr(pr, number, run, reason, identity, now, opts)
      {:error, _} = error -> {:halt, error}
    end
  end

  defp requeue_claimed_pr(pr, number, run, reason, identity, now, opts) do
    case Journal.reserve_merge_group_requeue(now, opts) do
      :ok ->
        enqueue_and_comment(pr, number, run, reason, identity, opts)

      {:error, :merge_group_requeue_limit_reached} ->
        release_claim(number, pr.head, identity, opts, :ok)

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp enqueue_and_comment(pr, number, run, reason, identity, opts) do
    case enqueue(pr, pr.node_id, pr.head, opts) do
      {:ok, entry} -> confirm_requeue(pr, entry, number, run, reason, identity, opts)
      {:error, _} = error -> release_claim(number, pr.head, identity, opts, error)
    end
  end

  defp confirm_requeue(pr, entry, number, run, reason, identity, opts) do
    case Journal.mark_landed(pr.number, pr.head, entry, opts) do
      :ok ->
        case comment_requeue(pr, run, reason, opts) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      {:error, _} = error ->
        release_claim(number, pr.head, identity, opts, error)
    end
  end

  defp release_claim(number, head, identity, opts, result) do
    _ = Journal.release_alert(number, head, identity, opts)

    case result do
      :ok -> {:halt, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp eligible_for_group_requeue?(
         %{number: number, head: head, merge_queue_entry: nil, auto_merge_request: nil} = pr,
         opts
       ) do
    pr.draft? == false and pr.review_decision == "APPROVED" and is_binary(head) and
      is_binary(pr.node_id) and
      Keyword.get(opts, :approved_fun, fn _, _ -> {:ok, true} end).(number, opts) == {:ok, true} and
      Keyword.get(opts, :revalidate_fun, &Observer.revalidate_approved_head/3).(
        number,
        head,
        opts
      ) == :ok and
      Keyword.get(opts, :attribution_fun, fn ticket ->
        Attribution.pull_request_clean?(ticket.number, opts)
      end).(pr) == {:ok, :clean}
  end

  defp eligible_for_group_requeue?(_pr, _opts), do: false

  defp comment_requeue(pr, run, reason, opts) do
    body =
      "Landing watcher requeued this approved PR after merge group run ##{run["id"]} failed due to #{reason}."

    Keyword.get(opts, :comment_fun, fn number, text, options ->
      Client.create_comment(to_string(number), text, options)
    end).(pr.number, body, opts)
  end

  defp enqueue(_pr, node_id, head, opts) do
    case Keyword.get(opts, :enqueue_fun) do
      fun when is_function(fun, 3) -> fun.(node_id, head, opts)
      _ -> enqueue_with_github(node_id, head, opts)
    end
  end

  defp enqueue_with_github(node_id, head, opts) do
    api = fn "post", "graphql", %{query: query, variables: variables} ->
      with {:ok, token} <- Transport.require_token(opts),
           do:
             Transport.github_graphql(
               Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
               token,
               query,
               variables,
               caller: "landing_watch_merge_group_requeue"
             )
    end

    Queue.enqueue(api, %{node_id: node_id, head: head})
  end
end

defmodule Aiur.Commands.CorrectiveTicket do
  @moduledoc false

  alias Aiur.CodeHost
  alias Aiur.Commands.{CorrectivePullRequest, CorrectiveTicketBody}
  alias Aiur.{Config, Tracker}

  @spec reconcile(Aiur.Decision.t(), map(), keyword()) :: {:ok, list()} | {:error, term()}
  def reconcile(decision, record, opts \\ []) do
    case Map.get(record, :corrective_ticket) do
      nil -> ensure(decision, record, opts)
      ticket -> observe_merge(record, ticket, opts)
    end
  end

  @spec successor(Aiur.Decision.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def successor(decision, record, pr, opts) do
    opts = Keyword.put_new_lazy(opts, :label_prefix, fn -> Config.settings!().tracker.github.label_prefix end)
    find_or_create(decision, record, Map.put(pr, :merged?, false), Keyword.put(opts, :successor, true))
  end

  defp ensure(decision, record, opts) do
    case CorrectivePullRequest.read(record.ticket.identifier, opts) do
      {:ok, %{merged?: true, number: number, merge_commit_sha: sha} = pr} when is_integer(number) and is_binary(sha) ->
        if record.route == :corrective_ticket do
          create_and_link(decision, record, pr, opts)
        else
          settle_merge(record, pr, opts)
        end

      {:error, _reason} = error ->
        error

      {:ok, %{state: :closed, merged?: false}} ->
        {:ok, [{:override_corrective_closed, %{action_id: record.action_id}}]}

      _unmerged_or_unknown ->
        if record.route == :corrective_ticket, do: {:error, :merged_pr_evidence_missing}, else: {:ok, []}
    end
  end

  defp create_and_link(decision, record, pr, opts) do
    with {:ok, ticket} <- find_or_create(decision, record, pr, opts),
         :ok <- link(decision.ticket.identifier, pr.number, record.action_id, ticket, opts),
         do: {:ok, link_facts(record, ticket, pr)}
  end

  defp settle_merge(record, pr, opts) do
    read = Keyword.get(opts, :merge_head, &CodeHost.override_merge_head/1)

    worker_head =
      case record.evidence do
        %{kind: :push, worker_reported: true, head_sha: sha} -> sha
        _ -> nil
      end

    pr = Map.put(pr, :worker_head_sha, worker_head)
    result = if record.state == :delivered and is_binary(worker_head), do: read.(pr), else: {:ok, pr}

    with {:ok, evidence} <- result do
      data = %{
        action_id: record.action_id,
        expected_version: Map.get(record, :merge_version, 1),
        pr_number: pr.number,
        head_sha: Map.get(evidence, :head_sha),
        worker_head_sha: worker_head,
        head_contains_worker_push: Map.get(evidence, :head_contains_worker_push, false),
        committed_at: Map.get(evidence, :committed_at)
      }

      {:ok, [{:override_merge_settled, data}]}
    end
  end

  defp link_facts(record, ticket, pr) do
    actions = Enum.uniq([Map.get(ticket, :origin_action_id, record.action_id), record.action_id])
    ticket = Map.delete(ticket, :origin_action_id)

    Enum.map(actions, fn action_id ->
      {:override_corrective_ticket, %{action_id: action_id, ticket: ticket, pr_number: pr.number, merge_commit_sha: pr.merge_commit_sha}}
    end)
  end

  defp find_or_create(decision, record, pr, opts) do
    earliest = decision.revisions |> Enum.map(& &1.recorded_at) |> Enum.min(DateTime)
    lookup_opts = [caller: "command_override_reconcile", since: DateTime.to_iso8601(DateTime.add(earliest, -300))]

    with {:ok, existing} <- find_existing(decision, record, lookup_opts, opts) do
      case existing do
        nil -> create(decision, record, pr, opts)
        ticket -> {:ok, ticket}
      end
    end
  end

  defp find_existing(decision, record, lookup_opts, opts) do
    # A newer override can arrive while the previous creation is in flight.
    # The keyed dispatch queue serializes those writes; reconcile every earlier
    # corrective marker before authorizing another creation.
    records = Enum.take_while(decision.overrides, &(&1.action_id != record.action_id)) ++ [record]

    Enum.reduce_while(Enum.reverse(records), {:ok, nil}, fn candidate, _acc ->
      find_candidate(candidate, record, lookup_opts, opts)
    end)
  end

  defp find_candidate(candidate, current, lookup_opts, opts) do
    if candidate.route in [:corrective_ticket, :replacement] or Map.get(candidate, :pr_merged) == :unknown or is_map(Map.get(candidate, :corrective_ticket)),
      do: lookup_candidate(candidate, current, lookup_opts, opts),
      else: {:cont, {:ok, nil}}
  end

  defp lookup_candidate(candidate, current, lookup_opts, opts) do
    marker = CorrectiveTicketBody.marker(candidate.action_id)

    case call(opts, :find, &Tracker.find_issue/2, [marker, lookup_opts]) do
      {:ok, nil} -> {:cont, {:ok, nil}}
      {:ok, raw} -> reuse_candidate(candidate, current, Map.put(normalize_ticket(raw), :origin_action_id, candidate.action_id), opts)
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp reuse_candidate(%{action_id: id}, %{action_id: id}, ticket, _opts) do
    {:halt, {:ok, ticket}}
  end

  defp reuse_candidate(_candidate, _current, ticket, opts) do
    case CorrectivePullRequest.read(ticket.identifier, opts) do
      {:ok, %{merged?: true}} ->
        {:cont, {:ok, nil}}

      {:ok, _unmerged} ->
        case Keyword.get(opts, :issue_closure, &Tracker.issue_closure/2).(ticket.identifier, 300_000) do
          {:ok, %{open?: true}} -> {:halt, {:ok, ticket}}
          {:ok, %{open?: false}} -> {:cont, {:ok, nil}}
          {:error, :unsupported} -> {:halt, {:error, :corrective_ticket_state_unavailable}}
          {:error, _reason} = error -> {:halt, error}
        end

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp create(decision, record, pr, opts) do
    with {:ok, [original]} <- call(opts, :issues, &Tracker.fetch_issue_states_by_ids/1, [[decision.ticket.identifier]]),
         attrs <- CorrectiveTicketBody.build(decision, record, pr, original.labels),
         attrs <- park_successor(attrs, opts),
         {:ok, raw} <- call(opts, :create, &Tracker.create_issue/2, [attrs, [caller: "command_override_create"]]) do
      {:ok, normalize_ticket(raw)}
    else
      {:ok, _missing} -> {:error, :original_ticket_missing}
      {:error, _reason} = error -> error
    end
  end

  defp park_successor(attrs, opts) do
    if Keyword.get(opts, :successor, false) do
      prefix = Keyword.fetch!(opts, :label_prefix)
      Map.update!(attrs, :labels, &["#{prefix}:parked" | List.delete(&1, "agent:todo")])
    else
      attrs
    end
  end

  defp normalize_ticket(raw) do
    %{identifier: to_string(Map.get(raw, "number", Map.get(raw, :number))), title: Map.get(raw, :title, Map.get(raw, "title")), url: Map.get(raw, "url", Map.get(raw, :url))}
  end

  defp link(original, pr_number, action_id, ticket, opts) do
    marker = CorrectiveTicketBody.marker(action_id)
    body = "#{marker}\nCommand override #{action_id} is tracked by corrective ticket ##{ticket.identifier}: #{ticket.url}"

    with :ok <- ensure_comment(original, marker, body, opts),
         do: ensure_comment(to_string(pr_number), marker, body, opts)
  end

  defp ensure_comment(target, marker, body, opts) do
    with {:ok, comments} <- call(opts, :comments, &Tracker.fetch_classified_issue_comments/1, [target]) do
      if Enum.any?(comments, &String.contains?(Map.get(&1, :body, Map.get(&1, "body", "")) || "", marker)),
        do: :ok,
        else: call(opts, :comment, &Tracker.create_comment/2, [target, body])
    end
  end

  defp observe_merge(record, ticket, opts) do
    case Keyword.get(opts, :pull_request, &Tracker.ticket_pull_request/1).(ticket.identifier) do
      {:ok, %{merged?: true, number: number, merge_commit_sha: sha}} when is_integer(number) and is_binary(sha) ->
        {:ok, [{:override_corrective_implemented, %{action_id: record.action_id, pr_number: number, merge_commit_sha: sha}}]}

      {:ok, _unmerged} ->
        {:ok, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp call(opts, key, default, args), do: apply(Keyword.get(opts, key, default), args)
end

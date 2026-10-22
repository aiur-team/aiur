defmodule Aiur.LandingWatch.ConflictRouting do
  @moduledoc """
  Routes an approved pull request that conflicts with its base to rebase-only rework (#4729).

  A conflicting PR can never land, and GitHub leaves a conflicting merge queue
  entry in place, so the watcher dequeues it, moves the ticket to rework, tells
  the agent to rebase only, and lifts the `agent:paused` override approved
  tickets carry so the rework can dispatch. The approval is left untouched for
  re-review to compare against.
  """

  alias Aiur.{CodeHost, Config, Tracker}
  alias Aiur.LandingWatch.Journal
  alias Aiur.LandingWatch.Observer
  alias Aiur.Orchestrator.TicketTransition

  @failure %{name: "Merge conflict with base"}

  @spec conflicting?(map()) :: boolean()
  def conflicting?(observation) do
    Map.get(observation, :mergeable) == "CONFLICTING" or
      Map.get(observation, :conflict_queue_persistent?, false)
  end

  @doc false
  @spec persistent_queue_conflict?(map(), keyword()) :: boolean()
  def persistent_queue_conflict?(%{merge_queue_entry: %{"state" => "UNMERGEABLE"}, mergeable: mergeable, number: number, head: head}, opts)
      when mergeable in ["MERGEABLE", "UNKNOWN"] and is_integer(number) and is_binary(head) do
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    key = "#{number}:#{head}"

    case Journal.update(opts, fn state ->
           rows = Map.get(state, "unmergeable_conflict_entries", %{})
           since = Map.get(rows, key) || now
           {:ok, Map.put(state, "unmergeable_conflict_entries", Map.put(rows, key, since)), since}
         end) do
      {:ok, since} -> now - since >= 5 * 60_000
      _ -> false
    end
  end

  def persistent_queue_conflict?(%{number: number, head: head}, opts) when is_integer(number) and is_binary(head) do
    key = "#{number}:#{head}"

    with {:ok, state} <- Journal.state(opts),
         rows when is_map(rows) <- Map.get(state, "unmergeable_conflict_entries", %{}),
         true <- Map.has_key?(rows, key) do
      Journal.update(opts, fn current ->
        current_rows = Map.get(current, "unmergeable_conflict_entries", %{})
        {:ok, Map.put(current, "unmergeable_conflict_entries", Map.delete(current_rows, key))}
      end)
    end

    false
  end

  def persistent_queue_conflict?(_, _), do: false

  @doc false
  @spec queue_prs_ahead(map(), keyword()) :: [pos_integer()]
  def queue_prs_ahead(%{number: number, merge_queue_entry: %{"position" => position}} = observation, opts)
      when is_integer(number) and is_integer(position) and position > 1 do
    case Keyword.get(opts, :queue_prs_ahead_fun, &Observer.prs_ahead/2).(observation, opts) do
      {:ok, numbers} when is_list(numbers) -> Enum.filter(numbers, &is_integer/1)
      _ -> []
    end
  end

  def queue_prs_ahead(_, _), do: []

  @doc "Takes the PR out of the queue, then routes it through `rework` with a rebase-only follow-up."
  @spec route(map(), (map(), [map()], keyword() -> :ok | {:error, term()}), keyword()) :: :ok | {:error, term()}
  def route(observation, rework, opts) do
    marker = "conflict-rework"

    with :ok <- withdraw(observation, opts),
         {:ok, claim} <- Journal.claim_alert(observation.number, observation.head, marker, opts),
         {:ok, completed?} <- follow_up_completed?(observation, opts) do
      route_if_incomplete(observation, rework, opts, claim, completed?)
    end
  end

  defp route_if_incomplete(_observation, _rework, _opts, _claim, true), do: :ok

  defp route_if_incomplete(observation, rework, opts, claim, false) do
    route_result(observation, claim, opts, invoke_rework(observation, rework, opts, claim))
  end

  defp invoke_rework(observation, rework, opts, claim) do
    rework.(
      observation,
      [@failure],
      opts
      |> Keyword.put(:conflict_rework_claim, claim)
      |> Keyword.put(:after_rework, fn issue, paused? ->
        complete_follow_up(observation, issue, Keyword.put(opts, :conflict_ticket_paused?, paused?))
      end)
    )
  end

  defp route_result(observation, _claim, opts, result) when result in [:conflict_already_rework, :conflict_not_routed] do
    _ = Journal.release_alert(observation.number, observation.head, "conflict-rework", opts)
    :ok
  end

  defp route_result(_observation, _claim, _opts, {:error, {:conflict_follow_up, _reason}} = error), do: error

  defp route_result(observation, :new, opts, {:error, reason}) do
    _ = Journal.release_alert(observation.number, observation.head, "conflict-rework", opts)
    {:error, reason}
  end

  defp route_result(_observation, _claim, _opts, result), do: result

  defp follow_up_completed?(observation, opts) do
    with {:ok, journal} <- Journal.state(opts) do
      entry = Map.get(journal, "#{observation.number}:#{observation.head}", %{})
      alerts = Map.get(entry, "alerts", %{})
      {:ok, Map.get(alerts, "conflict-rework-follow-up", false)}
    end
  end

  defp complete_follow_up(observation, issue, opts) do
    case follow_up(observation, issue, opts) do
      :ok ->
        case Journal.claim_alert(observation.number, observation.head, "conflict-rework-follow-up", opts) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:conflict_follow_up, reason}}
        end

      {:error, reason} ->
        {:error, {:conflict_follow_up, reason}}

      other ->
        {:error, {:conflict_follow_up, {:unconfirmed, other}}}
    end
  end

  defp withdraw(%{merge_queue_entry: nil, auto_merge_request: nil}, _opts), do: :ok

  defp withdraw(observation, opts) do
    case Keyword.get(opts, :withdraw_fun, &CodeHost.withdraw_landing/1).(observation.number) do
      {:ok, _actions} -> :ok
      {:error, reason, _actions} -> {:error, {:conflict_withdrawal_failed, reason}}
      {:error, reason} -> {:error, {:conflict_withdrawal_failed, reason}}
    end
  end

  defp follow_up(observation, issue, opts) do
    comment = Keyword.get(opts, :comment_fun, &Tracker.create_comment/2)
    write_marker = Keyword.get(opts, :write_marker_fun, &TicketTransition.write_marker/4)

    with :ok <- comment.(issue, comment_body(observation)) do
      maybe_lift_approval_pause(observation, issue, opts, write_marker)
    end
  end

  defp maybe_lift_approval_pause(observation, issue, opts, write_marker) do
    cond do
      not Keyword.get(opts, :conflict_ticket_paused?, false) ->
        :ok

      approval_pause_owned?(issue, opts) ->
        write_marker.(issue, :remove, Keyword.get_lazy(opts, :pause_label, &pause_label/0), writer: :landing_watch)

      true ->
        emit_held_conflict_attention(observation, issue, opts)
    end
  end

  defp approval_pause_owned?(issue, opts) do
    case Keyword.get(opts, :approval_pause_provenance_fun) do
      fun when is_function(fun, 1) -> fun.(issue) == true
      _ -> Journal.pause_writer(issue, opts) == {:ok, "approval_pause"}
    end
  end

  defp emit_held_conflict_attention(observation, issue, opts) do
    message = "Conflicting approved PR ##{observation.number} is held by #{pause_label()} on ticket #{issue}."
    marker = "conflict-held-pause"

    case Journal.claim_alert(observation.number, observation.head, marker, opts) do
      {:ok, :already_claimed} ->
        :ok

      {:ok, :new} ->
        emitter = Keyword.get(opts, :alert_emitter, &Aiur.Alerts.emit_system/2)

        case emitter.("ticket.#{issue}.agent.attention.conflicting_held_pr",
               central: true,
               durable: true,
               needs_attention: true,
               message: message,
               reason: message
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = Journal.release_alert(observation.number, observation.head, marker, opts)
            {:error, {:held_conflict_attention, reason}}

          other ->
            _ = Journal.release_alert(observation.number, observation.head, marker, opts)
            {:error, {:held_conflict_attention, {:unconfirmed, other}}}
        end

      {:error, reason} ->
        {:error, {:held_conflict_attention, reason}}
    end
  end

  @doc false
  @spec comment_body(map()) :: String.t()
  def comment_body(observation) do
    base = Map.get(observation, :base) || "the base branch"
    queue_context = queue_conflict_context(observation)

    """
    **Rebase only.** Approved PR ##{observation.number} conflicts with `#{base}`#{queue_context}, so the landing watcher took it out of the merge queue and moved this ticket to rework.

    Integrate `#{base}`, resolve the conflicts, and push. Make no other change. The approval at `#{observation.head}` stays on record so re-review can compare the contribution diff.
    """
  end

  defp queue_conflict_context(%{conflict_queue_persistent?: true} = observation) do
    ahead = Map.get(observation, :conflicting_queue_prs, [])

    case Enum.filter(ahead, &is_integer/1) do
      [] -> " (its merge-queue entry stayed UNMERGEABLE for five minutes)"
      numbers -> " (queued behind PRs " <> Enum.map_join(numbers, ", ", &"##{&1}") <> ")"
    end
  end

  defp queue_conflict_context(_), do: ""

  defp pause_label, do: "#{Config.settings!().tracker.github.label_prefix}:paused"
end

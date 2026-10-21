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
  alias Aiur.Orchestrator.TicketTransition

  @failure %{name: "Merge conflict with base"}

  @spec conflicting?(map()) :: boolean()
  def conflicting?(observation), do: Map.get(observation, :mergeable) == "CONFLICTING"

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

    """
    **Rebase only.** Approved PR ##{observation.number} conflicts with `#{base}`, so the landing watcher took it out of the merge queue and moved this ticket to rework.

    Integrate `#{base}`, resolve the conflicts, and push. Make no other change. The approval at `#{observation.head}` stays on record so re-review can compare the contribution diff.
    """
  end

  defp pause_label, do: "#{Config.settings!().tracker.github.label_prefix}:paused"
end

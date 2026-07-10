defmodule Aiur.Orchestrator.CommentWake do
  @moduledoc """
  Trusted-comment reactivation routing: idle promotion to rework, running-entry
  reactivation, PR-merged terminalization, and comment-rework retry scheduling.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger
  import Bitwise, only: [<<<: 2]

  alias Aiur.Events.UniversalSubscriptions
  alias Aiur.{Issue, Tracker}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, PrAnchored, State}

  @comment_rework_retry_delay_ms 2_000
  @comment_rework_max_attempts 5

  @spec maybe_reactivate_on_comment(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer()
        ) :: State.t()
  def maybe_reactivate_on_comment(%State{} = state, issue_number, source, event, attempt \\ 1) do
    case State.find_running_by_identifier(state.running, issue_number) do
      # An already-running entry (PR-anchored or legacy) resumes its SAME
      # session — a follow-up comment on a PR-anchored agent's PR resolves here
      # (identifier == to_string(pr#)) and never re-dispatches.
      running_entry when is_map(running_entry) ->
        reactivate_if_deactivated(state, running_entry, issue_number, source, event)

      _ ->
        PrAnchored.maybe_route_pr_anchored_or_legacy(state, issue_number, source, event, attempt)
    end
  end

  @spec mark_pr_merged_issue_done(State.t(), String.t() | integer()) :: State.t()
  def mark_pr_merged_issue_done(%State{} = state, identifier) do
    case Tracker.update_issue_state(to_string(identifier), "done") do
      :ok ->
        Orchestrator.clear_session_handle(identifier)

        case State.find_running_by_identifier(state.running, identifier) do
          %{issue: %Issue{id: issue_id}} ->
            Orchestrator.terminate_running_issue(state, issue_id, true)

          _ ->
            state
        end

      {:error, reason} ->
        Logger.warning("PR merge terminal transition skipped: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        state
    end
  end

  @doc false
  @spec trusted_comment_event?(map()) :: boolean()
  def trusted_comment_event?(event) when is_map(event) do
    Map.get(event, :author_trusted?) == true or Map.get(event, "author_trusted?") == true
  end

  @doc false
  @spec benign_review_pass_comment?(map()) :: boolean()
  def benign_review_pass_comment?(event) when is_map(event) do
    event
    |> comment_body()
    |> review_pass_comment?()
  end

  @doc false
  @spec maybe_transition_idle_issue_to_rework(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer()
        ) :: State.t()
  def maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt) do
    case transition_comment_issue_to_rework(issue_number, source, event) do
      :ok ->
        seed_idle_comment_wake_event(state, issue_number, event)

      {:skip, reason} ->
        Logger.info("#{source} ignored for idle issue: issue_identifier=#{issue_number} reason=#{inspect(reason)}")

        state

      {:error, reason} ->
        Logger.warning("#{source} rework transition skipped; state update failed: issue_identifier=#{issue_number} reason=#{inspect(reason)}")

        schedule_comment_rework_retry(state, issue_number, source, event, attempt, reason)
    end
  end

  @doc false
  @spec comment_rework_retry_delay_ms(pos_integer()) :: pos_integer()
  def comment_rework_retry_delay_ms(attempt) when is_integer(attempt) do
    power = (attempt - 1) |> max(0) |> min(4)
    comment_rework_retry_base_delay_ms() * (1 <<< power)
  end

  @doc false
  @spec comment_rework_max_attempts() :: pos_integer()
  def comment_rework_max_attempts do
    case Application.get_env(:aiur, :comment_rework_max_attempts) do
      attempts when is_integer(attempts) and attempts > 0 -> attempts
      _ -> @comment_rework_max_attempts
    end
  end

  @doc false
  @spec event_digest_summary(map()) :: String.t()
  def event_digest_summary(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"
    message = Map.get(event, "message") || Map.get(event, :message) || Map.get(event, "summary")

    case message do
      m when is_binary(m) and m != "" -> "#{topic}: #{m}"
      _ -> topic
    end
  end

  defp reactivate_if_deactivated(state, running_entry, issue_number, source, event) do
    if State.deactivated_running_entry?(running_entry) do
      transition_and_revalidate_comment_reactivation(
        state,
        running_entry,
        issue_number,
        source,
        event
      )
    else
      state
    end
  end

  defp schedule_comment_rework_retry(
         %State{} = state,
         issue_number,
         source,
         event,
         attempt,
         reason
       ) do
    max_attempts = comment_rework_max_attempts()

    if attempt >= max_attempts do
      Logger.warning("#{source} rework transition retry exhausted: issue_identifier=#{issue_number} attempts=#{attempt} reason=#{inspect(reason)}")
    else
      next_attempt = attempt + 1
      delay_ms = comment_rework_retry_delay_ms(attempt)

      Process.send_after(
        self(),
        {:retry_comment_rework, issue_number, source, event, next_attempt},
        delay_ms
      )

      Logger.info("#{source} rework transition retry scheduled: issue_identifier=#{issue_number} attempt=#{next_attempt}/#{max_attempts} delay_ms=#{delay_ms}")
    end

    state
  end

  defp seed_idle_comment_wake_event(%State{} = state, issue_number, event) do
    identifier = to_string(issue_number)

    UniversalSubscriptions.attach(identifier)

    state
    |> Orchestrator.enqueue_event_digest_item(identifier, [event], event)
    |> dispatch_reworked_comment_issue(identifier)
  end

  defp dispatch_reworked_comment_issue(%State{} = state, identifier) when is_binary(identifier) do
    case fetch_comment_dispatch_issue(identifier) do
      {:ok, %Issue{} = issue} ->
        dispatch_reworked_comment_issue(state, issue)

      {:skip, reason} ->
        Logger.info("Trusted comment dispatch deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        Orchestrator.schedule_poll_cycle_start()
        state

      {:error, reason} ->
        Logger.warning("Trusted comment dispatch deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        Orchestrator.schedule_poll_cycle_start()
        state
    end
  end

  defp dispatch_reworked_comment_issue(%State{} = state, %Issue{} = issue) do
    active = DispatchPolicy.active_state_set()
    terminal = DispatchPolicy.terminal_state_set()

    if DispatchPolicy.should_dispatch_issue?(issue, state, active, terminal) do
      Dispatcher.dispatch_issue(state, issue)
    else
      Orchestrator.schedule_poll_cycle_start()
      state
    end
  end

  defp fetch_comment_dispatch_issue(identifier) do
    case Tracker.fetch_issue_states_by_ids([identifier]) do
      {:ok, [%Issue{} = issue | _]} ->
        {:ok, issue}

      {:ok, []} ->
        fetch_comment_dispatch_issue_from_candidates(identifier)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_comment_dispatch_issue_from_candidates(identifier) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        case find_issue_by_identifier_or_id(issues, identifier) do
          %Issue{} = issue -> {:ok, issue}
          nil -> {:skip, :missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_issue_by_identifier_or_id(issues, identifier) when is_list(issues) do
    Enum.find(issues, fn
      %Issue{id: id, identifier: issue_identifier} ->
        id == identifier or issue_identifier == identifier

      _ ->
        false
    end)
  end

  defp transition_and_revalidate_comment_reactivation(
         state,
         running_entry,
         issue_number,
         source,
         event
       ) do
    issue_key = rework_issue_key(running_entry, issue_number)

    case transition_comment_issue_to_rework(issue_key, source, event) do
      :ok ->
        revalidate_comment_reactivation(state, running_entry, issue_number, source)

      {:skip, reason} ->
        context = comment_reactivation_context(running_entry, issue_number)
        Logger.info("#{source} ignored for inactive issue: #{context} reason=#{inspect(reason)}")
        state

      {:error, reason} ->
        context = comment_reactivation_context(running_entry, issue_number)

        Logger.warning("#{source} reactivation skipped; state update failed: #{context} reason=#{inspect(reason)}")

        state
    end
  end

  defp transition_comment_issue_to_rework(issue_number, _source, event) do
    cond do
      not trusted_comment_event?(event) ->
        {:skip, :untrusted_author}

      benign_review_pass_comment?(event) ->
        {:skip, :benign_review_pass_comment}

      true ->
        Tracker.update_issue_state(to_string(issue_number), "rework")
    end
  end

  defp comment_body(event) do
    comment = Map.get(event, :comment) || Map.get(event, "comment") || %{}

    if is_map(comment) do
      Map.get(comment, :body) || Map.get(comment, "body")
    end
  end

  defp review_pass_comment?(body) when is_binary(body) do
    body
    |> String.trim()
    |> String.downcase()
    |> String.match?(~r/^\[codex\]\s+review\s+passed\b/)
  end

  defp review_pass_comment?(_body), do: false

  defp comment_rework_retry_base_delay_ms do
    case Application.get_env(:aiur, :comment_rework_retry_delay_ms) do
      delay when is_integer(delay) and delay >= 0 -> delay
      _ -> @comment_rework_retry_delay_ms
    end
  end

  defp rework_issue_key(%{issue: %Issue{id: issue_id}}, _issue_number) when is_binary(issue_id),
    do: issue_id

  defp rework_issue_key(_running_entry, issue_number), do: issue_number

  defp revalidate_comment_reactivation(state, running_entry, issue_number, source) do
    context = comment_reactivation_context(running_entry, issue_number)

    case fetch_current_reactivation_issue(running_entry) do
      {:ok, %Issue{} = refreshed_issue} ->
        reactivate_current_issue(state, running_entry, refreshed_issue, issue_number, source)

      {:skip, reason} ->
        Logger.info("#{source} ignored for inactive issue: #{context} reason=#{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.warning("#{source} reactivation skipped; issue refresh failed: #{context} reason=#{inspect(reason)}")

        state
    end
  end

  defp fetch_current_reactivation_issue(%{issue: %Issue{id: issue_id} = issue})
       when is_binary(issue_id) do
    case Dispatcher.revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           DispatchPolicy.terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} -> {:ok, refreshed_issue}
      {:skip, %Issue{} = refreshed_issue} -> {:skip, refreshed_issue.state}
      {:skip, :missing} -> {:skip, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_current_reactivation_issue(_running_entry), do: {:skip, :missing_issue_id}

  defp reactivate_current_issue(state, running_entry, refreshed_issue, issue_number, source) do
    issue_id = refreshed_issue.id
    refreshed_entry = Map.put(running_entry, :issue, refreshed_issue)
    state = %{state | running: Map.put(state.running, issue_id, refreshed_entry)}

    Logger.info("#{source} reactivating: issue_id=#{issue_id} issue_identifier=#{issue_number}")

    {_reply, next_state} = Orchestrator.reactivate_issue(state, refreshed_entry)
    next_state
  end

  defp comment_reactivation_context(running_entry, issue_number) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{issue_number}"
  end
end

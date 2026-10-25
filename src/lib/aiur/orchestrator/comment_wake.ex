defmodule Aiur.Orchestrator.CommentWake do
  @moduledoc "Trusted comment routing and stable public wake API."

  require Logger

  alias Aiur.Orchestrator.CommentWake.{IdleRework, MergedPr, Reactivation, ReworkRetries}
  alias Aiur.Orchestrator.PrAnchored
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition

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
        Reactivation.reactivate_if_deactivated(state, running_entry, issue_number, source, event, attempt)

      _ ->
        PrAnchored.maybe_route_pr_anchored_or_legacy(state, issue_number, source, event, attempt)
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
  @spec event_digest_summary(map()) :: String.t()
  def event_digest_summary(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"
    message = Map.get(event, "message") || Map.get(event, :message) || Map.get(event, "summary")

    case message do
      m when is_binary(m) and m != "" -> "#{topic}: #{m}"
      _ -> topic
    end
  end

  @doc false
  @spec comment_body(map()) :: term()
  def comment_body(event) do
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

  @spec mark_pr_merged_issue_done(State.t(), String.t() | integer(), keyword()) :: State.t()
  defdelegate mark_pr_merged_issue_done(state, identifier, opts \\ []), to: MergedPr

  @spec merged_issue_target_state(String.t() | integer(), keyword()) :: String.t() | {:error, term()}
  defdelegate merged_issue_target_state(identifier, opts), to: MergedPr

  @spec maybe_transition_idle_issue_to_rework(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer()
        ) :: State.t()
  defdelegate maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt), to: IdleRework

  @spec comment_rework_retry_delay_ms(pos_integer()) :: pos_integer()
  defdelegate comment_rework_retry_delay_ms(attempt), to: ReworkRetries

  @spec comment_rework_max_attempts() :: pos_integer()
  defdelegate comment_rework_max_attempts(), to: ReworkRetries

  @spec schedule_comment_wake_retry(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer(),
          String.t()
        ) :: {State.t(), :scheduled | :exhausted}
  defdelegate schedule_comment_wake_retry(state, issue_number, source, event, attempt, reason_label), to: ReworkRetries

  @spec retryable_comment_rework_failure?(term()) :: boolean()
  defdelegate retryable_comment_rework_failure?(reason), to: ReworkRetries

  @spec comment_rework_retry_key(String.t() | integer(), String.t() | atom()) ::
          {String.t(), String.t()}
  defdelegate comment_rework_retry_key(issue_number, source), to: ReworkRetries

  @spec forget_comment_rework_retry(State.t(), String.t() | integer(), String.t() | atom()) ::
          State.t()
  defdelegate forget_comment_rework_retry(state, issue_number, source), to: ReworkRetries

  @spec cancel_comment_rework_retries(State.t()) :: State.t()
  defdelegate cancel_comment_rework_retries(state), to: ReworkRetries

  @doc false
  @spec reactivate_current_issue(State.t(), map(), Aiur.Issue.t(), String.t() | integer(), String.t() | atom(), keyword()) :: State.t()
  def reactivate_current_issue(state, running_entry, refreshed_issue, issue_number, source, opts \\ []) do
    issue_id = refreshed_issue.id
    refreshed_entry = Map.put(running_entry, :issue, refreshed_issue)
    state = %{state | running: Map.put(state.running, issue_id, refreshed_entry)}

    Logger.info("#{source} reactivating: issue_id=#{issue_id} issue_identifier=#{issue_number}")

    case TicketTransition.apply_effect(state, {:reactivate, refreshed_entry}) do
      {{:ok, :reactivated}, next_state} ->
        next_state

      {{:error, reason}, next_state} ->
        Reactivation.emit_comment_reactivation_deferred_alert(refreshed_entry, source, reason, opts)
        next_state
    end
  end
end

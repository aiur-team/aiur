defmodule Aiur.Orchestrator.CommentWake.ReworkRetries do
  @moduledoc "Bounded comment wake retries and timer lifecycle."

  require Logger

  alias Aiur.Orchestrator.State

  import Bitwise, only: [<<<: 2]

  @comment_rework_retry_delay_ms 2_000
  @comment_rework_max_attempts 5

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
  @spec schedule_comment_rework_retry(State.t(), String.t() | integer(), String.t() | atom(), map(), pos_integer(), term()) :: State.t()
  def schedule_comment_rework_retry(
        %State{} = state,
        issue_number,
        source,
        event,
        attempt,
        reason
      ) do
    max_attempts = comment_rework_max_attempts()
    key = comment_rework_retry_key(issue_number, source)

    # Any previously scheduled attempt for this issue+source is superseded by the
    # decision we are making now; cancel it so at most one timer per key is live.
    state = cancel_comment_rework_retry(state, key)

    cond do
      not retryable_comment_rework_failure?(reason) ->
        Logger.warning("#{source} rework transition failed permanently: issue_identifier=#{issue_number} attempts=#{attempt} reason=#{inspect(reason)}")

        state

      attempt >= max_attempts ->
        Logger.warning("#{source} rework transition retry exhausted: issue_identifier=#{issue_number} attempts=#{attempt} reason=#{inspect(reason)}")

        state

      true ->
        next_attempt = attempt + 1
        delay_ms = comment_rework_retry_delay_ms(attempt)

        timer_ref =
          Process.send_after(
            self(),
            {:retry_comment_rework, issue_number, source, event, next_attempt},
            delay_ms
          )

        Logger.info("#{source} rework transition retry scheduled: issue_identifier=#{issue_number} attempt=#{next_attempt}/#{max_attempts} delay_ms=#{delay_ms}")

        put_comment_rework_retry(state, key, {timer_ref, issue_number, source})
    end
  end

  @doc """
  Re-deliver a comment wake later because a transient, non-tracker condition
  blocked it.

  The PR-anchored path (`Aiur.Orchestrator.PrAnchored`) builds a synthetic work
  unit that carries no `agent:*` label and is not in the tracker, so the poll
  loop can never rediscover it. When the host-pressure admission gate holds that
  dispatch, dropping it would strand the work until a new human comment arrived.
  This re-arms the same bounded, escalating `{:retry_comment_rework, ...}` chain
  the tracker-failure path uses, so the held unit is re-offered to the gate on
  its own.

  Returns `{state, :scheduled | :exhausted}` so the caller can escalate when the
  chain runs out and the work really is being dropped.
  """
  @spec schedule_comment_wake_retry(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer(),
          String.t()
        ) :: {State.t(), :scheduled | :exhausted}
  def schedule_comment_wake_retry(%State{} = state, issue_number, source, event, attempt, reason_label)
      when is_integer(attempt) and is_binary(reason_label) do
    max_attempts = comment_rework_max_attempts()
    key = comment_rework_retry_key(issue_number, source)

    # At most one live timer per issue+source: the decision being made now
    # supersedes any earlier scheduled attempt.
    state = cancel_comment_rework_retry(state, key)

    if attempt >= max_attempts do
      {state, :exhausted}
    else
      next_attempt = attempt + 1
      delay_ms = comment_rework_retry_delay_ms(attempt)

      timer_ref =
        Process.send_after(
          self(),
          {:retry_comment_rework, issue_number, source, event, next_attempt},
          delay_ms
        )

      Logger.info(
        "#{source} comment wake retry scheduled: issue_identifier=#{issue_number} " <>
          "attempt=#{next_attempt}/#{max_attempts} delay_ms=#{delay_ms} reason=#{reason_label}"
      )

      {put_comment_rework_retry(state, key, {timer_ref, issue_number, source}), :scheduled}
    end
  end

  @doc """
  Is a failed rework transition worth retrying?

  The retry chain runs up to `comment_rework_max_attempts/0` attempts with
  escalating delays — a full minute of work at the default settings. That only
  makes sense for failures a later attempt could plausibly clear: 5xx responses,
  timeouts, DNS/TLS/transport faults, and rate limiting.

  Auth and permission failures cannot: a missing or rejected token stays missing
  or rejected for all five attempts, so retrying only burns a minute producing
  warnings. Client errors (4xx other than 408/429) are the same — the request
  itself is wrong, and repeating it verbatim will not fix it.
  """
  @spec retryable_comment_rework_failure?(term()) :: boolean()
  def retryable_comment_rework_failure?(:missing_github_token), do: false
  def retryable_comment_rework_failure?({:github, classification, _detail}) when classification in [:auth, :permission], do: false
  def retryable_comment_rework_failure?({:github, :http, %{status: status}}), do: retryable_status?(status)
  def retryable_comment_rework_failure?({:github_api_status, status}) when is_integer(status), do: retryable_status?(status)
  def retryable_comment_rework_failure?(_reason), do: true

  # 408 Request Timeout and 429 Too Many Requests are the two 4xx codes that a
  # later identical request can legitimately succeed at.
  defp retryable_status?(status) when status in [408, 429], do: true
  defp retryable_status?(status) when is_integer(status) and status in 400..499, do: false
  defp retryable_status?(_status), do: true

  @doc false
  @spec comment_rework_retry_key(String.t() | integer(), String.t() | atom()) ::
          {String.t(), String.t()}
  def comment_rework_retry_key(issue_number, source),
    do: {to_string(issue_number), to_string(source)}

  @doc """
  Forget the retry timer for `issue_number`/`source` because its message just fired.

  The timer has already been delivered at this point, so there is nothing to
  cancel — dropping the ref keeps the tracking map from growing without bound.
  """
  @spec forget_comment_rework_retry(State.t(), String.t() | integer(), String.t() | atom()) ::
          State.t()
  def forget_comment_rework_retry(%State{} = state, issue_number, source) do
    key = comment_rework_retry_key(issue_number, source)
    %{state | comment_rework_retries: Map.delete(comment_rework_retries(state), key)}
  end

  @doc """
  Cancel every outstanding comment-rework retry timer.

  Retry chains run up to `comment_rework_max_attempts/0` attempts with escalating
  delays, so an untracked timer can fire — and log — tens of seconds after the
  work that scheduled it is gone. `terminate/2` calls this so a stopping
  orchestrator never leaves a retry firing into an unrelated context.
  """
  @spec cancel_comment_rework_retries(State.t()) :: State.t()
  def cancel_comment_rework_retries(%State{} = state) do
    state
    |> comment_rework_retries()
    |> Map.keys()
    |> Enum.reduce(state, &cancel_comment_rework_retry(&2, &1))
  end

  @doc false
  @spec cancel_comment_rework_retry(State.t(), String.t() | integer(), String.t() | atom()) :: State.t()
  def cancel_comment_rework_retry(%State{} = state, issue_number, source),
    do: cancel_comment_rework_retry(state, comment_rework_retry_key(issue_number, source))

  defp cancel_comment_rework_retry(%State{} = state, key) do
    case Map.pop(comment_rework_retries(state), key) do
      {nil, _retries} ->
        state

      {{timer_ref, issue_number, source}, retries} ->
        # `false` means the timer already fired, so its message is in the mailbox
        # and cancelling alone would not stop the retry from running.
        if Process.cancel_timer(timer_ref, async: false, info: true) == false do
          flush_comment_rework_retry(issue_number, source)
        end

        %{state | comment_rework_retries: retries}
    end
  end

  # Selective receive on the exact scheduled message: pinned issue/source means
  # unrelated mailbox entries keep their position rather than being re-sent.
  defp flush_comment_rework_retry(issue_number, source) do
    receive do
      {:retry_comment_rework, ^issue_number, ^source, _event, _attempt} -> :ok
    after
      0 -> :ok
    end
  end

  defp put_comment_rework_retry(%State{} = state, key, entry),
    do: %{state | comment_rework_retries: Map.put(comment_rework_retries(state), key, entry)}

  defp comment_rework_retries(%State{comment_rework_retries: retries}) when is_map(retries),
    do: retries

  defp comment_rework_retries(_state), do: %{}

  defp comment_rework_retry_base_delay_ms do
    case Application.get_env(:aiur, :comment_rework_retry_delay_ms) do
      delay when is_integer(delay) and delay >= 0 -> delay
      _ -> @comment_rework_retry_delay_ms
    end
  end
end

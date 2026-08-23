defmodule Aiur.Orchestrator.StatusReason do
  @moduledoc false

  @type t ::
          :awaiting_dispatch
          | :prewarm_blocked
          | :orphaned_claim
          | :stale_claim
          | {:latched, non_neg_integer(), non_neg_integer()}
          | {:claim_released, atom() | String.t(), non_neg_integer() | nil}
          | {:transient, String.t() | nil, non_neg_integer() | nil}
          | {:paused, atom() | String.t() | nil}
          | {:paused, atom() | String.t() | nil, t()}

  @spec for_idle(boolean(), term(), non_neg_integer(), non_neg_integer()) :: t()
  def for_idle(_prewarm_blocked?, :lifetime, lifetime, maximum) when is_integer(lifetime) and is_integer(maximum),
    do: {:latched, lifetime, maximum}

  def for_idle(true, _trip, _lifetime, _maximum), do: :prewarm_blocked

  def for_idle(false, _trip, _lifetime, _maximum), do: :awaiting_dispatch

  @spec for_retry(String.t() | nil, non_neg_integer() | nil) :: t()
  def for_retry(error, due_in_ms), do: {:transient, error, due_in_ms}

  @spec for_claim_release(atom() | String.t(), non_neg_integer() | nil) :: t()
  def for_claim_release(cause, retry_in_ms), do: {:claim_released, cause, retry_in_ms}

  @spec for_pause(atom() | String.t() | nil) :: t()
  def for_pause(reason), do: {:paused, reason}

  @spec for_paused_retry(atom() | String.t() | nil, String.t() | nil, non_neg_integer() | nil) :: t()
  def for_paused_retry(reason, error, due_in_ms), do: {:paused, reason, for_retry(error, due_in_ms)}

  @spec render(t()) :: String.t()
  def render(:awaiting_dispatch), do: "awaiting-dispatch"
  def render(:prewarm_blocked), do: "prewarm-blocked"
  def render(:orphaned_claim), do: "orphaned claim: no live agent"
  def render(:stale_claim), do: "stale in-progress claim: no live agent"
  def render({:latched, lifetime, maximum}), do: "latched #{lifetime}/#{maximum}"

  def render({:claim_released, cause, retry_in_ms}) do
    retry = if is_integer(retry_in_ms), do: "; automatic re-claim #{format_duration(retry_in_ms)}", else: ""
    "claim released: #{humanize(cause)}#{retry}"
  end

  def render({:transient, error, due_in_ms}) do
    detail = if is_binary(error) and error != "", do: ": #{compact(error)}", else: ""
    retry = if is_integer(due_in_ms), do: ", retry #{format_duration(due_in_ms)}", else: ""
    "transient#{detail}#{retry}"
  end

  def render({:paused, reason}) do
    case reason do
      reason when reason in [:operator_pause, :label_override] -> "operator"
      :global_pause -> "run paused"
      :github_budget_hold -> "GitHub budget hold; automatic retry"
      reason when reason in [:agent_pause_request, :input_required, :blocker_dependency] -> "cooperative: #{humanize(reason)}"
      :before_run_failure -> "preflight failure"
      :usage_limit_exhausted -> "provider limit"
      nil -> "unknown"
      other -> humanize(other)
    end
  end

  def render({:paused, reason, retry_reason}), do: "#{render({:paused, reason})}; #{render(retry_reason)}"

  defp format_duration(milliseconds) when milliseconds < 60_000, do: "<1m"
  defp format_duration(milliseconds), do: "~#{div(milliseconds + 59_999, 60_000)}m"

  defp compact(error) do
    error
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp humanize(reason) when is_atom(reason), do: reason |> Atom.to_string() |> humanize()
  defp humanize(reason) when is_binary(reason), do: reason |> String.replace("_", " ") |> String.replace("-", " ")
  defp humanize(reason), do: inspect(reason)
end

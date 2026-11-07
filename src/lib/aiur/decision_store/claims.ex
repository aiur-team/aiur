defmodule Aiur.DecisionStore.Claims do
  @moduledoc """
  Pure rules for one Executor owning one open Decision (MPG-502).

  A claim is a journaled routing fact (`:executor_claimed` / `:executor_claim_released`)
  held on the Decision. It expires by clock comparison at call time; no sweeper runs.
  """

  alias Aiur.Decision

  @type refusal :: {:claimed, String.t(), DateTime.t()}

  @spec live(Decision.t(), DateTime.t()) :: map() | nil
  def live(%{executor_claim: %{expires_at: expires_at} = claim}, now),
    do: if(DateTime.compare(expires_at, now) == :gt, do: claim)

  def live(_decision, _now), do: nil

  @spec claim(Decision.t(), %{executor_id: String.t(), now: DateTime.t(), expires_at: DateTime.t()}) ::
          {:ok, map()} | {:error, refusal() | :command_not_open}
  def claim(decision, %{executor_id: id, now: now, expires_at: expires_at}) do
    live = live(decision, now)

    cond do
      decision.decision_status not in [:open, :deferred] or not is_nil(decision.answer) -> {:error, :command_not_open}
      live != nil and live.executor_id != id -> {:error, refusal(live)}
      true -> {:ok, %{executor_id: id, claimed_at: now, expires_at: expires_at}}
    end
  end

  @spec release(Decision.t(), %{executor_id: String.t(), now: DateTime.t()}) :: {:ok, :released} | {:error, refusal() | :not_claimed}
  def release(decision, %{executor_id: id, now: now}) do
    case live(decision, now) do
      nil -> {:error, :not_claimed}
      %{executor_id: ^id} -> {:ok, :released}
      other -> {:error, refusal(other)}
    end
  end

  @doc "Refuses an Executor actor other than the live claimant; humans, supervisors and system actors pass."
  @spec check_actor(Decision.t(), map(), DateTime.t()) :: :ok | {:error, refusal()}
  def check_actor(decision, actor, now) do
    case {Map.get(actor, :kind), live(decision, now)} do
      {:executor, %{executor_id: claimant} = claim} when claimant != actor.id -> {:error, refusal(claim)}
      _other -> :ok
    end
  end

  defp refusal(%{executor_id: id, expires_at: at}), do: {:claimed, id, at}
end

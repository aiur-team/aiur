defmodule Aiur.Codex.TurnOverrides do
  @moduledoc """
  Per-turn `turn/start` overrides read from the ticket's current labels.

  The launch command pins the effort and model a session started with, and a
  resumed thread keeps them (#7947). The runner refreshes the issue before
  every continuation turn, so resolving here lets a label change between two
  turns of one thread take effect on the next turn. Codex keeps a turn
  override for the turns after it, so an operator turn inherits the last one.
  """

  alias Aiur.CodingAgent
  alias Aiur.Issue

  @backend "codex"

  @doc """
  The `turn/start` params to merge for `issue`: `"effort"` when the ticket
  resolves an effort Codex accepts (a `model:<effort>` label, else the
  routing effort), and `"model"` when a `model:codex*` label names a model
  other than the one the session runs.
  """
  @spec params(map(), map()) :: map()
  def params(session, %Issue{} = issue) do
    %{}
    |> put_if("effort", effort(issue))
    |> put_if("model", model(session, issue))
  end

  def params(_session, _issue), do: %{}

  @doc "The effort this turn runs at: the per-turn override, else the session's launch effort."
  @spec effort(map(), map()) :: String.t() | nil
  def effort(session, issue), do: effort(issue) || Map.get(session, :effort)

  defp effort(%Issue{} = issue) do
    effort = CodingAgent.effort_for(issue)
    if effort in CodingAgent.efforts(@backend), do: effort
  end

  defp effort(_issue), do: nil

  defp model(session, issue) do
    with @backend <- CodingAgent.override_backend(issue),
         model when is_binary(model) <- CodingAgent.resolve_model(@backend, CodingAgent.model_for(issue)),
         false <- model == Map.get(session, :model) do
      model
    else
      _ -> nil
    end
  end

  defp put_if(params, _key, nil), do: params
  defp put_if(params, key, value), do: Map.put(params, key, value)
end

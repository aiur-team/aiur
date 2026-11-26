defmodule Aiur.LocalBudgetHold do
  @moduledoc "Extracts typed local budget holds shared by runners and retry scheduling."

  @doc false
  @spec reason(term()) :: map() | nil
  def reason({:aiur, :locally_held, hold}) when is_map(hold), do: hold
  def reason({:github, :local_hold, %{hold: hold}}) when is_map(hold), do: hold

  def reason({:github, :local_hold, %{reason: {:aiur, :locally_held, hold}}}) when is_map(hold),
    do: hold

  def reason({:github, :transport, %{reason: {:aiur, :locally_held, hold}}}) when is_map(hold), do: hold

  def reason({:workspace_github_connectivity_failed, _workspace, inner}),
    do: reason(inner)

  def reason({:github_auth_preflight_failed, %{classification: :local_hold} = diagnostic}),
    do: reason(Map.get(diagnostic, :detail))

  def reason(%{hold: hold}) when is_map(hold), do: hold
  def reason(%{reason: {:aiur, :locally_held, hold}}) when is_map(hold), do: hold
  def reason(:github_budget_broker_timeout), do: %{reason: :github_budget_broker_timeout}
  def reason(%{reason: :github_budget_broker_timeout} = detail), do: detail

  def reason({:github, classification, %{reason: :github_budget_broker_timeout} = detail})
      when classification in [:timeout, :local_hold], do: detail

  def reason({:github_auth_preflight_failed, %{classification: :timeout, detail: detail}}),
    do: reason(detail)

  def reason(_reason), do: nil
end

defmodule Aiur.Orchestrator.MergeTransition do
  @moduledoc false

  alias Aiur.GitHub.{Config, IssueState}

  @spec normalize(term()) :: term()
  def normalize({_target, {:error, {:no_state_label_written, issue}}} = outcome) when is_map(issue) do
    if closed_done?(issue), do: {"done", :ok}, else: outcome
  end

  def normalize(outcome), do: outcome

  @spec reason_name(term()) :: atom()
  def reason_name(reason) when is_atom(reason), do: reason
  def reason_name(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: reason_name(elem(reason, 0))
  def reason_name(_reason), do: :unknown

  defp closed_done?(issue) do
    prefix = Config.label_prefix()

    states =
      issue
      |> Map.get("labels", [])
      |> Enum.map(&Map.get(&1, "name", ""))
      |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
      |> Enum.reject(&IssueState.preserved_prefixed_label?(&1, prefix))

    IssueState.closed_issue?(issue) and states == ["#{prefix}:done"]
  end
end

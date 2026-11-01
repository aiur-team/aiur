defmodule Aiur.Orchestrator.IssueSync.ClosedIssueCleanup do
  @moduledoc false

  alias Aiur.GitHub.{Config, Labels, StatePolicy}
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Tracker

  @terminal_states ~w(done cancelled canceled budget-exhausted)

  @doc false
  @spec cleanup(Issue.t(), keyword()) :: :ok | :skipped | {:error, term()}
  def cleanup(%Issue{} = issue, opts \\ []) do
    if stale_lifecycle_labels?(issue) do
      identifier = issue.identifier || issue.id
      closure = Keyword.get(opts, :issue_closure_fun, fn id -> Tracker.issue_closure(id, 0) end)
      update = Keyword.get(opts, :update_state_fun, &write_terminal_state/3)
      prefix = Keyword.get(opts, :label_prefix, Config.label_prefix())

      with {:ok, %{open?: false, state_reason: reason}} <- closure.(identifier),
           target <- terminal_target(reason) do
        update.(identifier, target,
          expected_state: "Closed",
          clear_terminal_state_labels: Labels.state_labels(prefix) -- [StatePolicy.state_label(prefix, target)],
          clear_terminal_state_overrides: true
        )
      else
        {:ok, %{open?: true}} -> :skipped
        {:error, :unsupported} -> :skipped
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_issue_closure, other}}
      end
    else
      :skipped
    end
  end

  defp write_terminal_state(identifier, target, opts) do
    TicketTransition.write_state(identifier, target, Keyword.merge([writer: :issue_sync], opts))
  end

  @doc false
  @spec stale_lifecycle_labels?(Issue.t()) :: boolean()
  def stale_lifecycle_labels?(%Issue{state: state, state_labels: labels}) when is_list(labels) do
    DispatchPolicy.normalize_issue_state(state) == "closed" and
      Enum.any?(labels, &(DispatchPolicy.normalize_issue_state(&1) not in @terminal_states))
  end

  def stale_lifecycle_labels?(_issue), do: false

  defp terminal_target(reason) when reason in ["not_planned", "duplicate"], do: "cancelled"
  defp terminal_target(_reason), do: "done"
end

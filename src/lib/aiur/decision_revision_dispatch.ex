defmodule Aiur.DecisionRevisionDispatch do
  @moduledoc """
  Fresh target-state gate for corrective Decision revision delivery.

  The gate reuses the orchestrator dispatch revalidation seam but narrows the
  semantic `no_longer_applicable` result to fresh missing or terminal targets.
  Paused, blocked, or otherwise non-routable non-terminal work proceeds to the
  existing OperatorMessages capability/wake gates instead of being mistaken
  for a permanent outcome.
  """

  alias Aiur.{Issue, Tracker}
  alias Aiur.Orchestrator.{DispatchPolicy, Dispatcher}

  @type result ::
          {:ok, Issue.t()}
          | {:no_longer_applicable, :missing | {:terminal, String.t() | nil}}
          | {:error, term()}

  @doc "Refresh the target represented by a durable Decision ticket."
  @spec revalidate_target(map(), keyword()) :: result()
  def revalidate_target(decision, opts \\ []) when is_map(decision) and is_list(opts) do
    with {:ok, issue} <- target_issue(decision),
         {:ok, issue_fetcher} <- issue_fetcher(opts),
         {:ok, terminal_states} <- terminal_states(opts),
         {:ok, revalidate_fun} <- revalidate_fun(opts) do
      issue
      |> revalidate_fun.(issue_fetcher, terminal_states)
      |> classify_revalidation(terminal_states)
    end
  end

  defp target_issue(%{ticket: %{identifier: identifier} = ticket})
       when is_binary(identifier) and identifier != "" do
    {:ok,
     %Issue{
       id: identifier,
       identifier: identifier,
       title: Map.get(ticket, :title),
       url: Map.get(ticket, :url)
     }}
  end

  defp target_issue(_decision), do: {:error, :target_identity_missing}

  defp classify_revalidation({:ok, %Issue{} = issue}, _terminal_states), do: {:ok, issue}
  defp classify_revalidation({:skip, :missing}, _terminal_states), do: {:no_longer_applicable, :missing}

  defp classify_revalidation({:skip, %Issue{} = issue}, terminal_states) do
    if DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) do
      {:no_longer_applicable, {:terminal, issue.state}}
    else
      {:ok, issue}
    end
  end

  defp classify_revalidation({:error, reason}, _terminal_states) do
    {:error, {:target_revalidation_failed, reason}}
  end

  defp classify_revalidation(other, _terminal_states) do
    {:error, {:target_revalidation_failed, {:invalid_result, other}}}
  end

  defp issue_fetcher(opts) do
    case Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issue_states_by_ids/1) do
      fetcher when is_function(fetcher, 1) -> {:ok, fetcher}
      _other -> {:error, {:target_revalidation_context, :invalid_issue_fetcher}}
    end
  end

  defp terminal_states(opts) do
    states = Keyword.get_lazy(opts, :terminal_states, &DispatchPolicy.terminal_state_set/0)

    if is_struct(states, MapSet) do
      {:ok, states}
    else
      {:error, {:target_revalidation_context, :invalid_terminal_states}}
    end
  end

  defp revalidate_fun(opts) do
    case Keyword.get(opts, :revalidate_fun, &Dispatcher.revalidate_issue_for_dispatch/3) do
      fun when is_function(fun, 3) -> {:ok, fun}
      _other -> {:error, {:target_revalidation_context, :invalid_revalidator}}
    end
  end
end

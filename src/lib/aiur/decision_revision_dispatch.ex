defmodule Aiur.DecisionRevisionDispatch do
  @moduledoc """
  Fresh target-state gate for corrective Decision revision delivery.

  The gate reuses the orchestrator dispatch revalidation seam but narrows the
  semantic `no_longer_applicable` result to fresh missing or terminal targets.
  Paused, blocked, or otherwise non-routable non-terminal work proceeds to the
  existing OperatorMessages capability/wake gates instead of being mistaken
  for a permanent outcome.
  """

  alias Aiur.{Decision, DecisionAnswer, DecisionRevision, Issue, Tracker}
  alias Aiur.Orchestrator.{DispatchPolicy, Dispatcher}
  alias Aiur.Orchestrator.OperatorMessages

  @max_message_chars 7_800

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

  @doc "Refresh and send one corrective revision through OCC-3's correlated queue path."
  @spec dispatch(Decision.t(), keyword()) ::
          {:ok, map()} | {:no_longer_applicable, term()} | {:error, term()}
  def dispatch(%Decision{} = decision, opts \\ []) when is_list(opts) do
    with %DecisionRevision{} = revision <- List.last(decision.revisions),
         {:ok, %Issue{}} <- revalidate_target(decision, opts) do
      send_revision(decision, revision, opts)
    else
      nil -> {:error, :revision_missing}
      {:no_longer_applicable, _reason} = outcome -> outcome
      {:error, _reason} = error -> error
    end
  end

  @doc "Render a bounded corrective envelope without claiming prior effects changed."
  @spec render(Decision.t()) :: String.t()
  def render(%Decision{} = decision) do
    revision = List.last(decision.revisions)
    answer = revision.answer

    header = """
    Durable Decision revision for ticket #{decision.ticket.identifier}
    Decision: #{decision.decision_id}
    Request version: #{revision.decision_version}
    Revision sequence: #{revision.sequence}
    Revision action: #{revision.action_id}
    Prior action: #{revision.prior_action_id}
    Revised by: #{answer.actor.kind}:#{answer.actor.id || "unknown"}
    Question: #{decision.question}
    Reason: #{revision.reason}
    """

    footer = """

    This is corrective, append-only direction. Inspect the current workspace and target state before following it; earlier instructions may already have taken effect.
    After observing it, emit `decision.acknowledged` with decision_id `#{decision.decision_id}`, action_id `#{revision.action_id}`, and expected_version #{revision.decision_version}.
    When the revised work is complete, emit `decision.resolved` with the same correlation fields.
    """

    bounded_join(header, response_text(decision, answer), footer)
  end

  defp send_revision(decision, revision, opts) do
    attempt_id = Keyword.fetch!(opts, :attempt_id)
    retry_failed = Keyword.get(opts, :retry_failed, false)
    server = Keyword.get(opts, :operator_messages, Aiur.Orchestrator)
    send_fun = Keyword.get(opts, :send_fun, &OperatorMessages.send_correlated_operator_message/3)

    correlation = %{
      decision_id: decision.decision_id,
      decision_version: revision.decision_version,
      action_id: revision.action_id,
      attempt_id: attempt_id,
      prior_action_id: revision.prior_action_id,
      revision_sequence: revision.sequence,
      actor: revision.answer.actor,
      answer_content_hash: revision.answer.content_hash
    }

    payload = %{
      kind: :text,
      body: render(decision),
      delivery_policy: :checkpoint,
      action_id: revision.action_id,
      correlation: correlation,
      retry_failed: retry_failed
    }

    send_fun.(server, decision.ticket.identifier, payload)
  end

  defp response_text(decision, %DecisionAnswer{selected_option_id: option_id}) when is_binary(option_id) do
    label =
      decision.options
      |> Enum.find(&(&1.id == option_id))
      |> case do
        nil -> "unknown option"
        option -> option.label
      end

    "Replacement option `#{option_id}`: #{label}\n"
  end

  defp response_text(_decision, %DecisionAnswer{custom_response: response}) do
    "Replacement response: #{response}\n"
  end

  defp bounded_join(header, content, footer) do
    available = max(@max_message_chars - String.length(header) - String.length(footer), 0)
    header <> String.slice(content, 0, available) <> footer
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

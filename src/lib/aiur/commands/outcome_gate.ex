defmodule Aiur.Commands.OutcomeGate do
  @moduledoc """
  Shared rules for creator review handoffs and recorded outcomes.

  A ticket opts into creator review by carrying the `creator-facing` label. A
  handoff then requires an open Command routed to the creator. `engineering-only`
  tickets instead require an open Executor-only Command. After merge, a
  creator-facing ticket remains open until one of its Commands has a recorded
  answer from an operator or Executor with a non-empty reason. The Command is
  the durable outcome record: a retry reads its current projection, so repeated
  merge reconciliation is safe.

  Callers supply the current Commands and related issue states. Missing or
  incomplete evidence holds closure; callers must retry after new evidence.
  """

  alias Aiur.Commands.Routing.Policy

  @creator_label "creator-facing"
  @engineering_label "engineering-only"
  @open_statuses [:open, :deferred, :expired]
  @confirmed_statuses [:decided, :resolved]
  @authorized_actors [:operator, :operator_relayed, :executor]

  @type related_issue :: %{required(:state) => String.t(), optional(:triaged?) => boolean()}

  @doc "Validates the requested review audience against an actionable Command for this ticket."
  @spec validate_handoff(Enumerable.t(), String.t() | nil, [map()]) :: :ok | {:error, atom()}
  def validate_handoff(labels, identifier, decisions) when is_list(labels) and is_list(decisions) do
    cond do
      @creator_label in labels and not open_creator_command?(decisions, identifier) -> {:error, :missing_actionable_creator_command}
      @engineering_label in labels and not open_executor_command?(decisions, identifier) -> {:error, :missing_executor_command}
      true -> :ok
    end
  end

  def validate_handoff(_labels, _identifier, _decisions), do: {:error, :outcome_evidence_unavailable}

  @doc "Whether an opted-in creator ticket has a confirmed outcome with reason and authorized actor."
  @spec outcome_confirmed?(Enumerable.t(), String.t() | nil, [map()]) :: boolean()
  def outcome_confirmed?(labels, identifier, decisions) when is_list(labels) and is_list(decisions) do
    @creator_label not in labels or Enum.any?(for_ticket(decisions, identifier), &confirmed_outcome?/1)
  end

  def outcome_confirmed?(_labels, _identifier, _decisions), do: false

  @doc "Closure remains held when any child/follow-up is open or lacks explicit triage."
  @spec related_work_complete?([related_issue()], [related_issue()]) :: boolean()
  def related_work_complete?(children, followups) when is_list(children) and is_list(followups) do
    Enum.all?(children, &(closed?(&1) and triaged?(&1))) and Enum.all?(followups, &(closed?(&1) and triaged?(&1)))
  end

  def related_work_complete?(_children, _followups), do: false

  @doc "Reads explicit numeric child and follow-up references from an epic issue body."
  @spec related_issue_ids(term()) :: {:ok, %{children: [String.t()], followups: [String.t()]}} | {:error, :missing_epic_children | :invalid_epic_references}
  def related_issue_ids(body) when is_binary(body) do
    fields =
      body
      |> String.split("\n")
      |> Enum.reduce(%{}, &related_issue_field/2)

    children = Map.get(fields, "children", [])
    followups = Map.get(fields, "follow-ups", [])

    cond do
      children == [] -> {:error, :missing_epic_children}
      Map.get(fields, :invalid, false) -> {:error, :invalid_epic_references}
      true -> {:ok, %{children: children, followups: followups}}
    end
  end

  def related_issue_ids(_body), do: {:error, :missing_epic_children}

  @doc "Returns the merge target for a creator-facing ticket."
  @spec merge_target(Enumerable.t(), String.t() | nil, [map()], [map()]) :: String.t()
  def merge_target(labels, identifier, decisions, post_deploy_checks \\ []) do
    creator_outcome_pending? = @creator_label in labels and not outcome_confirmed?(labels, identifier, decisions)
    post_deploy_pending? = Enum.any?(post_deploy_checks, &pending_check?(&1, identifier))

    if creator_outcome_pending? or post_deploy_pending?, do: "human-review", else: "done"
  end

  defp open_creator_command?(decisions, identifier) do
    Enum.any?(for_ticket(decisions, identifier), fn decision -> open?(decision) and Policy.needs_you?(decision) end)
  end

  defp open_executor_command?(decisions, identifier) do
    Enum.any?(for_ticket(decisions, identifier), fn decision -> open?(decision) and Policy.executor_audience?(decision) end)
  end

  defp for_ticket(decisions, identifier) when is_binary(identifier) do
    Enum.filter(decisions, fn decision ->
      get_in(decision, [:ticket, :identifier]) == identifier or get_in(decision, ["ticket", "identifier"]) == identifier
    end)
  end

  defp for_ticket(_decisions, _identifier), do: []

  defp open?(%{decision_status: status}) when status in @open_statuses, do: true
  defp open?(%{"decision_status" => status}) when status in ["open", "deferred", "expired"], do: true
  defp open?(_decision), do: false

  defp confirmed_outcome?(%{decision_status: status, answer: answer}) when status in @confirmed_statuses and not is_nil(answer), do: authorized_answer?(answer)
  defp confirmed_outcome?(%{"decision_status" => status, "answer" => answer}) when status in ["decided", "resolved"] and is_map(answer), do: authorized_answer?(answer)
  defp confirmed_outcome?(_decision), do: false

  defp authorized_answer?(answer) do
    actor = Map.get(answer, :actor) || Map.get(answer, "actor") || %{}
    actor_kind = Map.get(actor, :kind) || Map.get(actor, "kind")
    reason = Map.get(answer, :rationale) || Map.get(answer, "rationale") || Map.get(answer, :custom_response) || Map.get(answer, "custom_response")
    actor_kind in @authorized_actors and is_binary(reason) and String.trim(reason) != ""
  end

  defp closed?(%{state: state}), do: closed_state?(state)
  defp closed?(%{"state" => state}), do: closed_state?(state)
  defp closed?(_issue), do: false

  defp closed_state?(state) when is_binary(state), do: String.downcase(state) in ["closed", "done", "completed"]
  defp closed_state?(_state), do: false

  defp triaged?(%{triaged?: true}), do: true
  defp triaged?(%{"triaged?" => true}), do: true
  defp triaged?(_issue), do: false

  defp pending_check?(%{"ticket" => ticket, "done_at" => nil}, identifier), do: to_string(ticket) == to_string(identifier)
  defp pending_check?(_check, _identifier), do: false

  defp related_issue_field(line, fields) do
    case Regex.run(~r/^\s*(Children|Follow-ups):\s*(.*?)\s*$/i, line) do
      [_, key, raw] ->
        refs = Regex.scan(~r/#([1-9][0-9]*)/, raw, capture: :all_but_first) |> List.flatten()
        remainder = Regex.replace(~r/#([1-9][0-9]*)/, raw, "") |> String.replace([",", " ", "\t"], "")

        fields
        |> Map.put(String.downcase(key), Enum.uniq(refs))
        |> Map.put(:invalid, Map.get(fields, :invalid, false) or remainder != "")

      _ ->
        fields
    end
  end
end

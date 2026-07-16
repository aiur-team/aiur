defmodule Aiur.DecisionApi.PublicLifecycleProjection do
  @moduledoc false

  alias Aiur.{DecisionAnswer, DecisionRevision, DecisionSanitizer}

  @spec answer(DecisionAnswer.t() | term()) :: map() | nil
  def answer(nil), do: nil

  def answer(%DecisionAnswer{} = answer) do
    %{
      "action_id" => answer.action_id,
      "decision_version" => answer.decision_version,
      "selected_option_id" => answer.selected_option_id,
      "custom_response" => answer.custom_response,
      "rationale" => answer.rationale,
      "actor" => actor(answer.actor),
      "supervisor_basis" => supervisor_basis(answer.supervisor_basis),
      "accepted_at" => timestamp(answer.accepted_at)
    }
  end

  def answer(_answer), do: nil

  @spec revision(DecisionRevision.t() | term()) :: map()
  def revision(%DecisionRevision{} = revision) do
    %{
      "sequence" => revision.sequence,
      "action_id" => revision.action_id,
      "prior_action_id" => revision.prior_action_id,
      "answer" => answer(revision.answer),
      "reason" => revision.reason,
      "recorded_at" => timestamp(revision.recorded_at)
    }
  end

  def revision(_revision), do: %{}

  @spec revision_outcomes(map() | term()) :: map()
  def revision_outcomes(outcomes) when is_map(outcomes) do
    Map.new(outcomes, fn {action_id, outcome} ->
      {action_id,
       %{
         "result" => outcome |> value(:result) |> atom_name(),
         "reason_class" => value(outcome, :reason_class),
         "occurred_at" => outcome |> value(:occurred_at) |> timestamp()
       }}
    end)
  end

  def revision_outcomes(_outcomes), do: %{}

  @spec revision_follow_ups(map() | term()) :: map()
  def revision_follow_ups(follow_ups) when is_map(follow_ups) do
    follow_ups
    |> DecisionSanitizer.follow_ups()
    |> Map.new(fn {action_id, follow_up} ->
      {action_id,
       %{
         "action_id" => value(follow_up, :action_id),
         "slug" => value(follow_up, :slug),
         "question" => value(follow_up, :question),
         "required_at" => follow_up |> value(:required_at) |> timestamp(),
         "handled_at" => follow_up |> value(:handled_at) |> timestamp(),
         "handled_by" => follow_up |> value(:handled_by) |> actor()
       }}
    end)
  end

  def revision_follow_ups(_follow_ups), do: %{}

  @spec dispatch_attempt(map() | term()) :: map()
  def dispatch_attempt(attempt) when is_map(attempt) do
    attempt = DecisionSanitizer.dispatch_attempt(attempt)

    %{
      "action_id" => value(attempt, :action_id),
      "attempt_id" => value(attempt, :attempt_id),
      "queue_item_id" => value(attempt, :queue_item_id),
      "status" => attempt |> value(:status) |> atom_name(),
      "attempted_at" => attempt |> value(:attempted_at) |> timestamp(),
      "queued_at" => attempt |> value(:queued_at) |> timestamp(),
      "delivered_at" => attempt |> value(:delivered_at) |> timestamp(),
      "restored_at" => attempt |> value(:restored_at) |> timestamp(),
      "consumed_at" => attempt |> value(:consumed_at) |> timestamp(),
      "failed_at" => attempt |> value(:failed_at) |> timestamp(),
      "failure_reason_class" => value(attempt, :failure_reason_class)
    }
  end

  def dispatch_attempt(_attempt), do: %{}

  @spec lifecycle_fact(map() | nil) :: map() | nil
  def lifecycle_fact(nil), do: nil

  def lifecycle_fact(fact) when is_map(fact) do
    fact = DecisionSanitizer.lifecycle_fact(fact)

    %{
      "action_id" => value(fact, :action_id),
      "actor" => fact |> value(:actor) |> actor(),
      "occurred_at" => fact |> value(:occurred_at) |> timestamp()
    }
  end

  defp actor(actor) when is_map(actor), do: %{"kind" => actor |> DecisionSanitizer.actor() |> value(:kind) |> atom_name()}
  defp actor(_actor), do: nil

  defp supervisor_basis(nil), do: nil

  defp supervisor_basis(basis) when is_map(basis) do
    policy_basis = value(basis, :policy_basis)

    %{
      "confidence" => value(basis, :confidence),
      "alternatives_considered" => value(basis, :alternatives_considered),
      "reversibility_belief" => basis |> value(:reversibility_belief) |> atom_name(),
      "policy_basis" => %{
        "authority" => policy_basis |> value(:authority) |> atom_name(),
        "kind" => value(policy_basis, :kind),
        "reversibility" => policy_basis |> value(:reversibility) |> atom_name(),
        "checks" => checks(policy_basis |> value(:checks)),
        "allow_non_reversible" => value(policy_basis, :allow_non_reversible)
      }
    }
  end

  defp supervisor_basis(_basis), do: nil
  defp checks(checks) when is_map(checks), do: Map.new(checks, fn {key, value} -> {to_string(key), value} end)
  defp checks(_checks), do: %{}
  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(_datetime), do: nil
  defp atom_name(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_name(value) when is_binary(value), do: value
  defp atom_name(_value), do: nil
end

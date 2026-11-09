defmodule Aiur.ExecutorWakeProjection do
  @moduledoc false

  alias Aiur.Events.Sanitizer

  @actions ~w(opened ready_for_review closed merged synchronize push passed failed paused parked_ready human_review)
  @ci_conclusions ~w(success failure cancelled timed_out action_required neutral skipped stale)
  @sha ~r/\A[0-9a-fA-F]{7,64}\z/

  @spec project(map()) :: {:ok, map()} | :ignore
  def project(event) when is_map(event) do
    topic = value(event, :topic)
    pr = typed_map(value(event, :pr))
    head = typed_map(value(pr, :head))
    head_sha = valid_sha(value(head, :sha) || value(event, :head_sha) || value(event, :sha))
    last_review_sha = valid_sha(value(pr, :last_review_sha) || value(event, :last_review_sha))

    if is_binary(topic) and String.ends_with?(topic, ".pr.ready_for_review") and head_sha != nil and
         head_sha == last_review_sha do
      :ignore
    else
      project(topic, event, pr, head_sha, last_review_sha)
    end
  end

  def project(_event), do: :ignore

  defp project("system.newsletter.ready" = topic, event, pr, head_sha, review_sha) do
    {:ok, record} = project("newsletter.ready", event, pr, head_sha, review_sha)
    {:ok, Map.merge(record, %{"topic" => topic, "topic_class" => topic, "report_path" => value(event, :report_path), "pdf_path" => value(event, :pdf_path)})}
  end

  defp project("executor.newsletter.failed" = topic, event, pr, head_sha, review_sha) do
    {:ok, record} = project("newsletter.failed", event, pr, head_sha, review_sha)
    fields = Map.new([:repo, :date, :stage, :reason, :log_path], &{Atom.to_string(&1), value(event, &1)})
    {:ok, Map.merge(record, Map.merge(fields, %{"topic" => topic, "topic_class" => topic}))}
  end

  defp project("executor.voice.session_ended" = topic, event, _pr, _head_sha, _last_review_sha) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    {:ok,
     %{
       "wake_id" => typed_id(value(event, :id)),
       "event_id" => typed_id(value(event, :id)),
       "topic" => topic,
       "topic_class" => "executor.voice",
       "ticket" => nil,
       "action" => "session_ended",
       "count" => 1,
       "first_seen_at" => now,
       "last_seen_at" => now
     }}
  end

  defp project("executor.decision.answered" = topic, event, _pr, _head_sha, _last_review_sha) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    {:ok,
     %{
       "wake_id" => typed_id(value(event, :id)),
       "event_id" => typed_id(value(event, :id)),
       "topic" => topic,
       "topic_class" => "executor.decision",
       "decision_id" => value(event, :decision_id),
       "ticket" => nil,
       "action" => "answered",
       "count" => 1,
       "first_seen_at" => now,
       "last_seen_at" => now
     }}
  end

  defp project(topic, event, pr, head_sha, last_review_sha) do
    if is_binary(topic) and not String.starts_with?(topic, "executor.") do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok,
       %{
         "wake_id" => typed_id(value(event, :id)),
         "topic" => topic,
         "topic_class" => topic_class(topic),
         "event_id" => typed_id(value(event, :id)),
         "ticket" => ticket_from_topic(topic),
         "pr_number" => positive_integer(value(pr, :number) || value(event, :pr_number) || value(event, :pull_request_number)),
         "head_sha" => head_sha,
         "last_review_sha" => last_review_sha,
         "action" => enum(value(event, :action) || action_from_topic(topic), @actions),
         "observed_state" => value(event, :observed_state),
         "observed_updated_at" => value(event, :observed_updated_at),
         "draft" => strict_boolean(first_present(value(pr, :draft), value(event, :draft))),
         "author_trusted?" => trusted_github_author?(event),
         "author_id" => positive_integer(value(event, :author_id)),
         "ci_conclusion" => ci_conclusion(event, topic),
         "needs_attention" => strict_boolean(value(event, :needs_attention)),
         "count" => 1,
         "first_seen_at" => now,
         "last_seen_at" => now
       }
       |> observation_marker(event)}
    else
      :ignore
    end
  end

  @doc """
  Adds the accepted answer, its ticket, and the ticket's Build Order feature and
  epic to an `executor.decision.answered` wake, so the Executor can act without
  extra reads (#7874). Answer text is sanitized and named in `untrusted_fields`.
  `feature`/`epic` come from `feature_lookup` (ticket number ->
  `{:ok, %{feature, epic}} | :unknown`) and are `nil` when it has no owner,
  is absent, or exits.
  """
  @spec with_answer(map(), Aiur.Decision.t(), (pos_integer() -> {:ok, map()} | :unknown) | nil) :: map()
  def with_answer(record, decision, feature_lookup \\ nil) do
    case Aiur.Decision.answer_for_action(decision, decision.active_action_id) do
      nil ->
        record

      answer ->
        ticket = Aiur.Commands.override_target_ticket(decision).identifier
        {feature, epic} = owner(ticket, feature_lookup)

        record
        |> Map.merge(%{"ticket" => ticket, "feature" => feature, "epic" => epic})
        |> Map.merge(answer_fields(answer))
        |> Map.put("untrusted_fields", ~w(custom_response question_answers feedback))
    end
  end

  @doc """
  Adds a changed premise's answers to a `premise-changed` attention wake: the
  new answer under the answered-wake keys (`nil` fields when mooted) and the old
  answer, in the same shape, under `previous`.
  """
  @spec with_premise_answers(map(), Aiur.DecisionAnswer.t() | nil, Aiur.DecisionAnswer.t() | nil) :: map()
  def with_premise_answers(record, answer, previous) do
    record
    |> Map.merge(answer_fields(answer))
    |> Map.merge(%{
      "previous" => if(previous, do: answer_fields(previous)),
      "untrusted_fields" => ~w(custom_response question_answers feedback previous moot_reason)
    })
  end

  defp answer_fields(nil), do: Map.new(~w(option_id question_answers custom_response feedback rejected actor actor_source), &{&1, nil})

  defp answer_fields(answer) do
    question_answers = question_answers(answer.custom_response)

    %{
      "option_id" => answer.selected_option_id,
      "question_answers" => strip(question_answers),
      "custom_response" => if(question_answers, do: nil, else: strip(answer.custom_response)),
      "feedback" => strip(answer.feedback),
      "rejected" => answer.rejected,
      "actor" => actor(answer.actor),
      "actor_source" => answer.actor |> source() |> then(&(&1 && to_string(&1)))
    }
  end

  defp actor(%{kind: kind} = actor), do: %{"kind" => to_string(kind), "id" => Map.get(actor, :id)}
  defp actor(_actor), do: nil

  defp source(actor) when is_map(actor), do: Map.get(actor, :source)
  defp source(_actor), do: nil

  # Multi-question answers are stored JSON-encoded in custom_response (Commands.Answering.QuestionAnswers).
  defp question_answers(response) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, %{"kind" => "question_answers", "question_answers" => answers}} when is_map(answers) -> answers
      _other -> nil
    end
  end

  defp question_answers(_response), do: nil

  # The lookup is injected so this component does not depend on build-orders. A
  # dead or slow registry must not crash the listener and lose the answer.
  defp owner(ticket, lookup) when is_binary(ticket) and is_function(lookup, 1) do
    with {number, ""} <- Integer.parse(ticket),
         {:ok, %{feature: feature, epic: epic}} when is_binary(feature) <- lookup.(number) do
      {feature, epic}
    else
      _unknown -> {nil, nil}
    end
  catch
    :exit, _reason -> {nil, nil}
  end

  defp owner(_ticket, _lookup), do: {nil, nil}

  defp strip(text) when is_binary(text), do: Sanitizer.strip_untrusted_text(text)
  defp strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  defp strip(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, strip(value)} end)
  defp strip(other), do: other

  defp observation_marker(record, event) do
    case value(event, :observation) do
      "initial_sync" -> Map.put(record, "observation", "initial_sync")
      _ -> record
    end
  end

  defp topic_class("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [_ticket, suffix] -> "ticket." <> suffix
      _ -> "ticket"
    end
  end

  defp topic_class(topic), do: topic

  defp action_from_topic("ticket." <> rest) do
    case String.split(rest, ".") do
      [_ticket, "branch", "push"] -> "push"
      [_ticket, "ci", outcome] when outcome in ["passed", "failed"] -> outcome
      [_ticket, "agent", "handoff", "human_review"] -> "human_review"
      _ -> nil
    end
  end

  defp action_from_topic(_topic), do: nil

  defp ci_conclusion(event, topic) do
    value = value(event, :ci_conclusion) || value(event, :conclusion)

    case {value, topic} do
      {nil, "ticket." <> rest} ->
        case String.split(rest, ".") do
          [_ticket, "ci", "passed"] -> "success"
          [_ticket, "ci", "failed"] -> "failure"
          _ -> nil
        end

      _ ->
        enum(value, @ci_conclusions)
    end
  end

  defp ticket_from_topic(topic) do
    case Regex.run(~r/\Aticket\.([^.]+)\./, topic) do
      [_, ticket] -> ticket
      _ -> nil
    end
  end

  defp typed_map(map) when is_map(map), do: map
  defp typed_map(_other), do: %{}

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp typed_id(value) when is_integer(value) and value > 0, do: value
  defp typed_id(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp valid_sha(value) when is_binary(value), do: if(Regex.match?(@sha, value), do: String.downcase(value), else: nil)
  defp valid_sha(_value), do: nil

  defp enum(value, allowed) when is_atom(value), do: enum(Atom.to_string(value), allowed)
  defp enum(value, allowed) when is_binary(value), do: if(value in allowed, do: value, else: nil)
  defp enum(_value, _allowed), do: nil

  defp strict_boolean(value) when is_boolean(value), do: value
  defp strict_boolean(_value), do: nil

  defp trusted_github_author?(event) do
    value(event, :source) in [:github, "github"] and value(event, :author_trusted?) == true
  end

  defp first_present(nil, fallback), do: fallback
  defp first_present(value, _fallback), do: value
end

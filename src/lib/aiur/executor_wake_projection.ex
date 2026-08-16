defmodule Aiur.ExecutorWakeProjection do
  @moduledoc false

  @actions ~w(opened ready_for_review closed merged synchronize push passed failed paused parked_ready)
  @ci_conclusions ~w(success failure cancelled timed_out action_required neutral skipped stale)
  @sha ~r/\A[0-9a-fA-F]{7,64}\z/

  @spec project(map()) :: {:ok, map()} | :ignore
  def project(event) when is_map(event) do
    topic = value(event, :topic)

    if is_binary(topic) and not String.starts_with?(topic, "executor.") do
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      pr = typed_map(value(event, :pr))
      head = typed_map(value(pr, :head))

      {:ok,
       %{
         "wake_id" => typed_id(value(event, :id)),
         "topic" => topic,
         "topic_class" => topic_class(topic),
         "event_id" => typed_id(value(event, :id)),
         "ticket" => ticket_from_topic(topic),
         "pr_number" => positive_integer(value(pr, :number) || value(event, :pr_number)),
         "head_sha" => valid_sha(value(head, :sha) || value(event, :head_sha) || value(event, :sha)),
         "action" => enum(value(event, :action) || action_from_topic(topic), @actions),
         "draft" => strict_boolean(first_present(value(pr, :draft), value(event, :draft))),
         "author_trusted?" => value(event, :author_trusted?) == true,
         "ci_conclusion" => ci_conclusion(event, topic),
         "needs_attention" => strict_boolean(value(event, :needs_attention)),
         "count" => 1,
         "first_seen_at" => now,
         "last_seen_at" => now
       }}
    else
      :ignore
    end
  end

  def project(_event), do: :ignore

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

  defp first_present(nil, fallback), do: fallback
  defp first_present(value, _fallback), do: value
end

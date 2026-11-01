defmodule Aiur.Orchestrator.CommentWake.ReviewRelay do
  @moduledoc false

  alias Aiur.Orchestrator.CommentWake
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.ReviewFindings

  @spec for_running_worker?(map(), map()) :: boolean()
  def for_running_worker?(running_entry, event) do
    get_in(running_entry, [:control, Access.key(:status)]) == :working and
      Aiur.Orchestrator.DispatchPolicy.normalize_issue_state(get_in(running_entry, [:issue, Access.key(:state)])) ==
        "in-progress" and
      (review_submission?(event) or blocking_pr_comment?(event))
  end

  @spec enqueue(Aiur.Orchestrator.State.t(), String.t() | integer(), map()) :: Aiur.Orchestrator.State.t()
  def enqueue(state, issue_number, event) do
    {text, message_id} = review_relay_message(event, issue_number)
    payload = %{body: text, origin: :internal, delivery_policy: :checkpoint, message_id: message_id}
    {_result, next_state} = OperatorMessages.enqueue_operator_message(state, to_string(issue_number), text, payload)
    next_state
  end

  defp review_submission?(event) do
    comment = event_value(event, "comment", :comment, %{})
    is_map(comment) and (Map.has_key?(comment, "state") or Map.has_key?(comment, :state))
  end

  defp blocking_pr_comment?(event), do: CommentWake.comment_body(event) |> ReviewFindings.blocking_body?()

  defp review_relay_message(event, issue_number) do
    comment = event_value(event, "comment", :comment, %{})
    pr = event_value(event, "pull_request", :pull_request, %{})
    review_url = event_value(comment, "html_url", :html_url, nil)
    body = event_value(comment, "body", :body, "")
    body = if is_binary(body), do: body, else: ""
    review_id = event_value(comment, "id", :id, nil)
    pr_number = event_value(pr, "number", :number, nil) || pr_number_from_url(review_url) || issue_number

    text = review_relay_text(pr_number, review_url, body)
    {text, review_message_id(review_id, event, issue_number)}
  end

  defp event_value(map, string_key, atom_key, default) when is_map(map),
    do: Map.get(map, string_key) || Map.get(map, atom_key) || default

  defp event_value(_map, _string_key, _atom_key, default), do: default

  defp pr_number_from_url(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url, capture: :all_but_first) do
      [number] -> number
      _ -> nil
    end
  end

  defp pr_number_from_url(_url), do: nil

  defp review_relay_text(pr_number, review_url, body) do
    label = if ReviewFindings.blocking_body?(body), do: "Blocking:", else: "Review:"

    ["PR ##{pr_number} review findings", review_url, label, review_body_excerpt(body)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp review_body_excerpt(body) do
    blocking_line = ~r/^\s*(?:[#]{1,6}\s*)?(?:blocking(?: findings| issues)?|blockers?|must fix|changes required)\s*:/im
    before_merge_request = ~r/\b(?:update|rebase|merge|fix)\b[^\n.!?]*\bbefore merge\b/i

    case Regex.run(blocking_line, body, return: :index) || Regex.run(before_merge_request, body, return: :index) do
      [{offset, _length}] -> String.slice(body, offset, 1_200)
      _ -> String.slice(String.trim(body), 0, 1_200)
    end
  end

  defp review_message_id(id, _event, issue_number) when is_integer(id), do: "pr-review:#{issue_number}:#{id}"

  defp review_message_id(id, _event, issue_number) when is_binary(id) and id != "",
    do: "pr-review:#{issue_number}:#{id}"

  defp review_message_id(_id, event, issue_number),
    do: "pr-review:#{issue_number}:event:#{inspect(event_value(event, "id", :id, nil))}"
end

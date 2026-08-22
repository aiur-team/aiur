defmodule Aiur.Webhooks.EventKey do
  @moduledoc """
  Derives a stable semantic key for a GitHub webhook payload.

  `X-GitHub-Delivery` identifies a delivery attempt group, not an event. Two
  genuinely different deliveries can carry the same underlying event — a manual
  redelivery created after the original expired, an event that GitHub fans out
  to more than one subscription, or a poller-sourced record of the same change.
  Delivery-id dedupe cannot see any of those, so handlers get a second key
  derived from the payload itself.

  Every key is built from fields that are stable for one underlying event and
  that change when the event genuinely changes: the object's own id plus the
  action plus the object's `updated_at` (or the sha, for pushes and pull
  request head movement). An edit to a comment therefore produces a new key
  rather than being swallowed as a duplicate of the original.

  Returns `nil` for event types with no meaningful identity here and for
  payloads missing the fields the key needs. `nil` means "do not dedupe", which
  keeps an unrecognised payload flowing rather than dropping it.
  """

  @spec derive(term(), term()) :: String.t() | nil
  def derive(event_name, payload) when is_binary(event_name) and is_map(payload) do
    with repo when is_binary(repo) <- repository(payload),
         parts when is_list(parts) <- identity(event_name, payload) do
      Enum.join([event_name, repo | parts], ":")
    else
      _ -> nil
    end
  end

  def derive(_event_name, _payload), do: nil

  defp identity("issues", payload) do
    with issue when is_map(issue) <- Map.get(payload, "issue"),
         number when is_integer(number) <- Map.get(issue, "number"),
         action when is_binary(action) <- Map.get(payload, "action"),
         updated_at when is_binary(updated_at) <- Map.get(issue, "updated_at") do
      [Integer.to_string(number), action, label_name(payload), updated_at]
    else
      _ -> nil
    end
  end

  defp identity("issue_comment", payload), do: comment_identity(payload, "issue")
  defp identity("pull_request_review_comment", payload), do: comment_identity(payload, "pull_request")

  defp identity("pull_request", payload) do
    with pull_request when is_map(pull_request) <- Map.get(payload, "pull_request"),
         number when is_integer(number) <- Map.get(pull_request, "number"),
         action when is_binary(action) <- Map.get(payload, "action"),
         updated_at when is_binary(updated_at) <- Map.get(pull_request, "updated_at") do
      [Integer.to_string(number), action, head_sha(pull_request), updated_at]
    else
      _ -> nil
    end
  end

  defp identity("pull_request_review", payload) do
    with review when is_map(review) <- Map.get(payload, "review"),
         id when is_integer(id) <- Map.get(review, "id"),
         action when is_binary(action) <- Map.get(payload, "action") do
      [Integer.to_string(id), action, to_string(Map.get(review, "state", ""))]
    else
      _ -> nil
    end
  end

  defp identity("push", payload) do
    with ref when is_binary(ref) <- Map.get(payload, "ref"),
         after_sha when is_binary(after_sha) <- Map.get(payload, "after") do
      [ref, after_sha]
    else
      _ -> nil
    end
  end

  defp identity(workflow, payload) when workflow in ["check_suite", "check_run", "workflow_run"] do
    object = Map.get(payload, workflow)

    with object when is_map(object) <- object,
         id when is_integer(id) <- Map.get(object, "id") do
      [Integer.to_string(id), to_string(Map.get(object, "status", "")), to_string(Map.get(object, "conclusion", ""))]
    else
      _ -> nil
    end
  end

  defp identity(event_type, payload) when event_type in ["sub_issues", "issue_dependencies"] do
    # Edge events carry no `updated_at`, so the action plus the two endpoint
    # numbers is the stable identity of one underlying graph mutation. A
    # redelivery of the same mutation dedups; a genuinely different edge or
    # action derives a different key.
    with action when is_binary(action) <- Map.get(payload, "action"),
         left when is_integer(left) <- Map.get(payload, left_number(event_type)),
         right when is_integer(right) <- Map.get(payload, right_number(event_type)) do
      [Integer.to_string(left), Integer.to_string(right), action]
    else
      _ -> nil
    end
  end

  defp identity(_event_name, _payload), do: nil

  defp left_number("sub_issues"), do: "parent_issue_number"
  defp left_number("issue_dependencies"), do: "blocked_issue_number"
  defp left_number(_event_type), do: nil

  defp right_number("sub_issues"), do: "sub_issue_number"
  defp right_number("issue_dependencies"), do: "blocking_issue_number"
  defp right_number(_event_type), do: nil

  defp comment_identity(payload, parent_field) do
    with comment when is_map(comment) <- Map.get(payload, "comment"),
         id when is_integer(id) <- Map.get(comment, "id"),
         action when is_binary(action) <- Map.get(payload, "action"),
         parent when is_map(parent) <- Map.get(payload, parent_field),
         number when is_integer(number) <- Map.get(parent, "number") do
      [Integer.to_string(number), Integer.to_string(id), action, to_string(Map.get(comment, "updated_at", ""))]
    else
      _ -> nil
    end
  end

  # A labeled/unlabeled pair can share the second-resolution `updated_at` of
  # the issue, so the label name keeps the two events distinct.
  defp label_name(payload) do
    case Map.get(payload, "label") do
      %{"name" => name} when is_binary(name) -> name
      _ -> ""
    end
  end

  defp head_sha(pull_request) do
    case Map.get(pull_request, "head") do
      %{"sha" => sha} when is_binary(sha) -> sha
      _ -> ""
    end
  end

  defp repository(payload) do
    case Map.get(payload, "repository") do
      %{"full_name" => full_name} when is_binary(full_name) and full_name != "" ->
        full_name

      _other ->
        # `sub_issues` / `issue_dependencies` carry no `repository` object;
        # their endpoint repos live in `*_repo` fields. Any one of them names
        # the delivery's repo for the purpose of a dedup key.
        payload
        |> Map.take(["parent_issue_repo", "sub_issue_repo", "blocked_issue_repo", "blocking_issue_repo"])
        |> Enum.find_value(fn {_key, value} -> if is_binary(value) and value != "", do: value end)
    end
  end
end

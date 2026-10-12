defmodule Aiur.Events.GithubWebhook.ReconcileHints do
  @moduledoc """
  The `{:reconcile, hint}` a state-owned delivery normalizes to: a nudge to run
  the reconciler that owns the event, never a second event shape. See
  "Publish vs reconcile" on `Aiur.Events.GithubWebhook.Normalizer`.
  """

  alias Aiur.Events.GithubWebhook.Identity

  @type result :: {:reconcile, map()} | {:drop, term()} | {:error, term()}

  @spec ci_reconcile(map(), String.t(), term()) :: result()
  def ci_reconcile(pr, event_type, action) do
    case Identity.ticket_from_head_ref(pr) do
      nil ->
        {:drop, {:unresolved_ticket, event_type, action}}

      ticket ->
        {:reconcile,
         %{
           kind: :ci,
           ticket: ticket,
           head_sha: get_in(pr, ["head", "sha"]),
           source: event_type,
           action: action
         }}
    end
  end

  @spec check_reconcile(map(), String.t()) :: result()
  def check_reconcile(subject, event_type) do
    pull_requests = Map.get(subject, "pull_requests") || []

    tickets =
      pull_requests
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Identity.ticket_from_head_ref/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case tickets do
      [] ->
        {:drop, {:unresolved_ticket, event_type, "completed"}}

      tickets ->
        {:reconcile,
         %{
           kind: :ci,
           tickets: tickets,
           head_sha: Map.get(subject, "head_sha"),
           conclusion: Map.get(subject, "conclusion"),
           source: event_type,
           action: "completed"
         }}
    end
  end

  @spec review_thread_reconcile(map(), map(), String.t(), String.t()) :: result()
  def review_thread_reconcile(payload, thread, action, repo) do
    thread_id = Map.get(thread, "node_id")
    pull_request = Map.get(payload, "pull_request")

    cond do
      not is_binary(thread_id) or thread_id == "" ->
        {:error, {:malformed_payload, "pull_request_review_thread"}}

      # A delivery whose pull request carries no head repository cannot be
      # routed to a ticket: there is nothing to compare the tracked repo
      # against. That is a malformed payload, not an untracked repository — the
      # drop reason would otherwise read `{:untracked_head_repository, nil}`,
      # which hides a gap in the payload behind the language of a tracking
      # decision.
      not named_head_repo?(pull_request) ->
        {:error, {:malformed_payload, "pull_request_review_thread"}}

      not tracked_head_repo?(pull_request, repo) ->
        {:drop, {:untracked_head_repository, get_in(pull_request, ["head", "repo", "full_name"])}}

      ticket = Identity.ticket_from_head_ref(pull_request) ->
        {:reconcile,
         %{
           kind: :review_thread,
           ticket: ticket,
           action: action,
           thread_id: thread_id,
           generation: Map.get(payload, "updated_at") || Map.get(thread, "updated_at")
         }}

      true ->
        {:drop, {:unresolved_ticket, "pull_request_review_thread", action}}
    end
  end

  defp named_head_repo?(pull_request) when is_map(pull_request) do
    case get_in(pull_request, ["head", "repo", "full_name"]) do
      delivered when is_binary(delivered) and delivered != "" -> true
      _other -> false
    end
  end

  defp named_head_repo?(_pull_request), do: false

  defp tracked_head_repo?(pull_request, repo) when is_map(pull_request) and is_binary(repo) do
    case get_in(pull_request, ["head", "repo", "full_name"]) do
      delivered when is_binary(delivered) and delivered != "" ->
        String.downcase(delivered) == String.downcase(repo)

      _other ->
        false
    end
  end

  defp tracked_head_repo?(_pull_request, _repo), do: false
end

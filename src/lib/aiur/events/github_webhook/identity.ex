defmodule Aiur.Events.GithubWebhook.Identity do
  @moduledoc """
  Resolves a delivery to the ticket identifier the fleet keys on. See "Ticket
  identity" on `Aiur.Events.GithubWebhook.Normalizer`.
  """

  alias Aiur.RecentMerge
  alias Aiur.TicketBranch

  @spec pull_request_identity(map(), keyword()) :: {:ok, String.t(), integer()} | {:drop, term()} | {:error, term()}
  def pull_request_identity(payload, opts \\ []) do
    pr = Map.get(payload, "pull_request")
    pr_number = if is_map(pr), do: Map.get(pr, "number")

    if is_map(pr) and is_integer(pr_number) do
      case ticket_for_pull_request(pr, opts) do
        nil -> {:drop, {:unresolved_ticket, "pull_request", pr_number}}
        ticket -> {:ok, ticket, pr_number}
      end
    else
      {:error, {:malformed_payload, "pull_request"}}
    end
  end

  defp ticket_for_pull_request(pr, opts) do
    ticket_from_head_ref(pr) || ticket_from_pr_body(Map.get(pr, "body")) || commit_ticket(pr, opts)
  end

  defp commit_ticket(pr, opts) do
    if Keyword.get(opts, :allow_commit_messages, false) and
         Map.get(pr, "commit_messages_unavailable", false) != true,
       do: List.first(linked_ticket_identifiers(pr))
  end

  @spec ticket_from_head_ref(map()) :: String.t() | nil
  def ticket_from_head_ref(pr) do
    case get_in(pr, ["head", "ref"]) do
      ref when is_binary(ref) -> TicketBranch.ticket_id_from_ref("refs/heads/" <> ref)
      _other -> nil
    end
  end

  # An `issue_comment` delivery on a pull request carries the PR body as
  # `issue.body` but no head ref. Every Aiur PR description opens with a
  # closing keyword, so that keyword is the ticket mapping for this one case.
  @spec ticket_from_pr_body(term()) :: String.t() | nil
  def ticket_from_pr_body(body) when is_binary(body) do
    RecentMerge.closing_issue_identifiers_in_body(body) |> List.first()
  end

  def ticket_from_pr_body(_body), do: nil

  @doc "Returns ticket ids explicitly linked by the body or commit messages."
  @spec linked_ticket_identifiers(map()) :: [String.t()]
  def linked_ticket_identifiers(pr) do
    repository = get_in(pr, ["base", "repo", "full_name"])
    body = Map.get(pr, "body")
    commit_messages = Map.get(pr, "commit_messages", [])
    linked_ids = RecentMerge.linked_issue_identifiers(struct(RecentMerge, summary: body, repository: repository, commit_messages: commit_messages))
    Enum.uniq(linked_ids)
  end

  @spec ticket_identifier(term()) :: String.t() | nil
  def ticket_identifier(number) when is_integer(number) and number > 0, do: Integer.to_string(number)

  def ticket_identifier(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> Integer.to_string(parsed)
      _other -> nil
    end
  end

  def ticket_identifier(_number), do: nil
end

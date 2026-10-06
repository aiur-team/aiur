defmodule Aiur.AllowedContributors.Candidate do
  @moduledoc """
  The normalized shape both producers hand to `Aiur.AllowedContributors`.

  Only authenticated, structural GitHub fields are read: `issue.user.id`,
  `issue.user.login`, `issue.user.type`, `issue.performed_via_github_app`,
  `issue.created_at`, and the issue number. The title, body, labels, comments,
  and the delivery's `sender` are never read — the author is who GitHub says
  *created* the issue, not who sent this delivery (a transfer is sent by the
  transferrer) and not a login mentioned anywhere in the text.
  """

  alias Aiur.Issue

  @type source :: :webhook | :poll
  @type t :: %{
          number: pos_integer() | nil,
          author_id: pos_integer() | nil,
          author_login: String.t() | nil,
          author_type: String.t() | nil,
          via_app?: boolean(),
          created_at: DateTime.t() | nil,
          source: source()
        }

  @doc "Builds a candidate from a verified `issues` webhook delivery's `issue` object."
  @spec from_webhook_issue(map()) :: t()
  def from_webhook_issue(issue) when is_map(issue) do
    user = if is_map(issue["user"]), do: issue["user"], else: %{}

    %{
      number: positive(issue["number"]),
      author_id: positive(user["id"]),
      author_login: string(user["login"]),
      author_type: string(user["type"]),
      # A missing provenance key is unknown, and unknown fails closed.
      via_app?: not Map.has_key?(issue, "performed_via_github_app") or not is_nil(issue["performed_via_github_app"]),
      created_at: datetime(issue["created_at"]),
      source: :webhook
    }
  end

  @doc "Builds a candidate from an `Aiur.Issue` normalized by the open-issue poll."
  @spec from_issue(Issue.t()) :: t()
  def from_issue(%Issue{} = issue) do
    %{
      number: positive(parse_number(issue.id)),
      author_id: positive(issue.creator_id),
      author_login: string(issue.creator_login),
      author_type: string(issue.creator_type),
      via_app?: issue.created_via_app? != false,
      created_at: issue.created_at,
      source: :poll
    }
  end

  defp parse_number(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp parse_number(_id), do: nil

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp datetime(_value), do: nil

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end

defmodule Aiur.DecisionTicketKey do
  @moduledoc false

  alias Aiur.{Bounded, TrackerIdentity}

  @type t :: String.t() | {:github, String.t(), String.t(), String.t()}

  @spec from_ticket(map()) :: t() | nil
  def from_ticket(ticket) when is_map(ticket) do
    identity = Map.get(ticket, :tracker_identity)
    identifier = Map.get(ticket, :identifier)

    if TrackerIdentity.joinable?(identity) do
      github_key(identity.owner, identity.repository, identity.identifier)
    else
      from_url(Map.get(ticket, :url), identifier) || fallback_key(ticket, identifier)
    end
  end

  def from_ticket(_ticket), do: nil

  defp from_url(url, identifier) when is_binary(identifier) do
    case Bounded.github_issue_reference(url) do
      {:ok, %{owner: owner, repository: repository, kind: "issues", identifier: ^identifier}} ->
        github_key(owner, repository, identifier)

      _other ->
        nil
    end
  end

  defp from_url(_url, _identifier), do: nil

  defp github_key(owner, repository, identifier),
    do: {:github, String.downcase(owner), String.downcase(repository), identifier}

  defp fallback_key(ticket, identifier), do: Map.get(ticket, :id) || identifier
end

defmodule Aiur.Instance.LeaseStore.TicketKey do
  @moduledoc false

  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.TrackerIdentity

  @doc "Canonical repository-qualified ticket key shared by dispatch, workers and observers."
  @spec ticket_key(term()) :: {:ok, String.t()} | {:error, :invalid_ticket_key}
  def ticket_key(%TrackerIdentity{} = identity) do
    key_from_identity(identity, identity.identifier) || {:error, :invalid_ticket_key}
  end

  def ticket_key(%{tracker_identity: %TrackerIdentity{} = identity} = ticket) do
    identifier = Map.get(ticket, :identifier) || Map.get(ticket, :number) || identity.identifier
    key_from_identity(identity, identifier) || {:error, :invalid_ticket_key}
  end

  def ticket_key(%{"tracker_identity" => %TrackerIdentity{} = identity} = ticket) do
    key_from_identity(identity, Map.get(ticket, "identifier") || Map.get(ticket, "number")) ||
      {:error, :invalid_ticket_key}
  end

  def ticket_key(%{tracker_identity: %TrackerIdentity{} = identity, number: number}),
    do: key_from_identity(identity, number) || {:error, :invalid_ticket_key}

  def ticket_key(%{"tracker_identity" => %TrackerIdentity{} = identity, "number" => number}),
    do: key_from_identity(identity, number) || {:error, :invalid_ticket_key}

  def ticket_key(%{number: number} = ticket), do: key_from_parts(repo_from_map(ticket), number)

  def ticket_key(%{"number" => number} = ticket),
    do: key_from_parts(repo_from_map(ticket), number)

  def ticket_key(%{identifier: identifier}), do: ticket_key(identifier)
  def ticket_key(%{"identifier" => identifier}), do: ticket_key(identifier)

  def ticket_key(number) when is_integer(number) and number > 0,
    do: key_from_parts(GitHubConfig.repo(), number)

  def ticket_key(value) when is_binary(value) do
    value = String.trim(value)

    case Regex.run(~r{^([^/#]+)/([^/#]+)#(\d+)$}, value) do
      [_, owner, repository, number] ->
        key_from_parts("#{owner}/#{repository}", number)

      _ ->
        case Regex.run(~r/^#?(\d+)$/, value) do
          [_, number] -> key_from_parts(GitHubConfig.repo(), number)
          _ -> {:error, :invalid_ticket_key}
        end
    end
  end

  def ticket_key(_ticket), do: {:error, :invalid_ticket_key}

  defp key_from_identity(%TrackerIdentity{} = identity, identifier) do
    if TrackerIdentity.joinable?(identity) and parse_number(identifier) == parse_number(identity.identifier) do
      key_from_parts("#{identity.owner}/#{identity.repository}", identifier)
    end
  end

  defp key_from_parts(repo, number) when is_binary(repo) do
    case {String.split(String.trim(repo), "/"), parse_number(number)} do
      {[owner, repository], n} when owner != "" and repository != "" and is_integer(n) ->
        {:ok, "#{String.downcase(owner)}/#{String.downcase(repository)}##{n}"}

      _ ->
        {:error, :invalid_ticket_key}
    end
  end

  defp key_from_parts(_, _), do: {:error, :invalid_ticket_key}

  defp parse_number(number) when is_integer(number) and number > 0, do: number

  defp parse_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_number(_), do: nil

  defp repo_from_map(ticket) do
    repository =
      Map.get(ticket, :repository) || Map.get(ticket, "repository") ||
        Map.get(ticket, :repo) || Map.get(ticket, "repo")

    case repository do
      value when is_binary(value) -> value
      %{full_name: name} when is_binary(name) -> name
      %{"full_name" => name} when is_binary(name) -> name
      _ -> GitHubConfig.repo()
    end
  end
end

defmodule Aiur.TrackerIdentity do
  @moduledoc """
  Versioned, repository-qualified identity for tracker records.

  A display identifier is intentionally retained as a locator, but only a
  `:joinable` identity with a configured repository and opaque provider ID can
  be used as a cross-surface join key.
  """

  @version 1
  @max_provider_id_bytes 512

  @derive {Jason.Encoder,
           only: [
             :version,
             :status,
             :kind,
             :owner,
             :repository,
             :provider_id,
             :database_id,
             :identifier,
             :reason
           ]}
  defstruct version: @version,
            status: :unjoinable,
            kind: nil,
            owner: nil,
            repository: nil,
            provider_id: nil,
            database_id: nil,
            identifier: nil,
            reason: :legacy

  @type repository :: {String.t(), String.t()}

  @type reason ::
          :legacy
          | :missing_configured_repository
          | :invalid_configured_repository
          | :repository_mismatch
          | :missing_provider_identity
          | :invalid_provider_identity
          | :invalid_display_identifier

  @type t :: %__MODULE__{
          version: pos_integer(),
          status: :joinable | :unjoinable,
          kind: :github | nil,
          owner: String.t() | nil,
          repository: String.t() | nil,
          provider_id: String.t() | nil,
          database_id: pos_integer() | nil,
          identifier: String.t() | nil,
          reason: reason() | nil
        }

  @doc """
  Builds a GitHub identity from a provider issue and the configured/requested
  repositories. The requested repository and any repository named by the
  response must match the configured repository exactly (case-insensitively,
  as GitHub repository names are case-insensitive).
  """
  @spec from_github(map(), repository(), repository()) :: {:ok, t()} | {:error, reason()}
  def from_github(issue, configured_repository, requested_repository) when is_map(issue) do
    with {:ok, {owner, repository}} <- normalize_repository(configured_repository, :invalid_configured_repository),
         {:ok, requested_repository} <- normalize_repository(requested_repository, :repository_mismatch),
         :ok <- ensure_same_repository({owner, repository}, requested_repository),
         :ok <- ensure_response_repository(issue, {owner, repository}),
         {:ok, provider_id} <- provider_id(Map.get(issue, "node_id")),
         {:ok, database_id} <- database_id(Map.get(issue, "database_id")),
         {:ok, identifier} <- display_identifier(Map.get(issue, "number")) do
      {:ok,
       %__MODULE__{
         version: @version,
         status: :joinable,
         kind: :github,
         owner: owner,
         repository: repository,
         provider_id: provider_id,
         database_id: database_id,
         identifier: identifier,
         reason: nil
       }}
    end
  end

  def from_github(_issue, _configured_repository, _requested_repository), do: {:error, :invalid_provider_identity}

  @doc """
  Returns an explicit nonjoinable identity while retaining only safe locator
  context that was already present at the trusted boundary.
  """
  @spec unjoinable(reason(), keyword()) :: t()
  def unjoinable(reason, opts \\ []) when is_atom(reason) and is_list(opts) do
    {owner, repository} =
      case {Keyword.get(opts, :owner), Keyword.get(opts, :repository)} do
        {owner, repository} when is_binary(owner) and is_binary(repository) ->
          {String.trim(owner), String.trim(repository)}

        _ ->
          {nil, nil}
      end

    %__MODULE__{
      version: @version,
      status: :unjoinable,
      kind: Keyword.get(opts, :kind, :github),
      owner: owner,
      repository: repository,
      database_id: database_id_or_nil(Keyword.get(opts, :database_id)),
      identifier: display_identifier_or_nil(Keyword.get(opts, :identifier)),
      reason: reason
    }
  end

  @spec joinable?(term()) :: boolean()
  def joinable?(%__MODULE__{
        version: @version,
        status: :joinable,
        kind: :github,
        owner: owner,
        repository: repository,
        provider_id: provider_id,
        identifier: identifier,
        reason: nil
      }) do
    with {:ok, {^owner, ^repository}} <-
           normalize_repository({owner, repository}, :invalid_configured_repository),
         {:ok, _provider_id} <- provider_id(provider_id),
         {:ok, ^identifier} <- display_identifier(identifier) do
      true
    else
      _ -> false
    end
  end

  def joinable?(_identity), do: false

  @doc false
  @spec github_key(term()) :: {:github, String.t(), String.t(), String.t()} | nil
  def github_key(%__MODULE__{} = identity) do
    if joinable?(identity) do
      {:github, String.downcase(identity.owner), String.downcase(identity.repository), identity.provider_id}
    end
  end

  def github_key(_identity), do: nil

  defp normalize_repository({owner, repository}, reason) do
    with {:ok, owner} <- repository_part(owner),
         {:ok, repository} <- repository_part(repository) do
      {:ok, {owner, repository}}
    else
      _ -> {:error, reason}
    end
  end

  defp normalize_repository(_, reason), do: {:error, reason}

  defp repository_part(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and not String.contains?(trimmed, "/") do
      {:ok, trimmed}
    else
      {:error, :invalid}
    end
  end

  defp repository_part(_value), do: {:error, :invalid}

  defp ensure_same_repository(configured, requested) do
    if same_repository?(configured, requested), do: :ok, else: {:error, :repository_mismatch}
  end

  defp ensure_response_repository(issue, configured) do
    case response_repositories(issue) do
      :absent ->
        :ok

      {:ok, responses} ->
        Enum.reduce_while(responses, :ok, &ensure_response_match(&1, configured, &2))

      :error ->
        {:error, :repository_mismatch}
    end
  end

  defp ensure_response_match(response, configured, :ok) do
    case ensure_same_repository(configured, response) do
      :ok -> {:cont, :ok}
      {:error, _reason} -> {:halt, {:error, :repository_mismatch}}
    end
  end

  defp response_repositories(issue) do
    [response_repository_url(issue), response_repository_object(issue)]
    |> Enum.reduce_while({:ok, []}, fn
      :absent, {:ok, responses} -> {:cont, {:ok, responses}}
      {:ok, response}, {:ok, responses} -> {:cont, {:ok, [response | responses]}}
      :error, _responses -> {:halt, :error}
    end)
    |> case do
      {:ok, []} -> :absent
      {:ok, responses} -> {:ok, responses}
      :error -> :error
    end
  end

  defp response_repository_url(issue) do
    case Map.fetch(issue, "repository_url") do
      :error -> :absent
      {:ok, url} -> parse_response_repository_url(url)
    end
  end

  defp parse_response_repository_url(url) when is_binary(url) do
    with %URI{scheme: "https", host: "api.github.com", path: "/repos/" <> path} <- URI.parse(url),
         [owner, repository] <- String.split(path, "/", trim: true),
         {:ok, response} <- normalize_repository({owner, repository}, :repository_mismatch) do
      {:ok, response}
    else
      _ -> :error
    end
  end

  defp parse_response_repository_url(_url), do: :error

  defp response_repository_object(issue) do
    case Map.fetch(issue, "repository") do
      :error ->
        :absent

      {:ok, %{"owner" => %{"login" => owner}, "name" => repository}} ->
        case normalize_repository({owner, repository}, :repository_mismatch) do
          {:ok, response} -> {:ok, response}
          {:error, _reason} -> :error
        end

      {:ok, _repository} ->
        :error
    end
  end

  defp same_repository?({configured_owner, configured_repository}, {requested_owner, requested_repository}) do
    String.downcase(configured_owner) == String.downcase(requested_owner) and
      String.downcase(configured_repository) == String.downcase(requested_repository)
  end

  defp provider_id(nil), do: {:error, :missing_provider_identity}

  defp provider_id(value) when is_binary(value) do
    if value != "" and value == String.trim(value) and byte_size(value) <= @max_provider_id_bytes do
      {:ok, value}
    else
      {:error, :invalid_provider_identity}
    end
  end

  defp provider_id(_value), do: {:error, :invalid_provider_identity}

  defp database_id(nil), do: {:ok, nil}
  defp database_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp database_id(_value), do: {:error, :invalid_provider_identity}

  defp display_identifier(value) when is_integer(value) and value > 0, do: {:ok, Integer.to_string(value)}

  defp display_identifier(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, Integer.to_string(number)}
      _ -> {:error, :invalid_display_identifier}
    end
  end

  defp display_identifier(_value), do: {:error, :invalid_display_identifier}

  defp display_identifier_or_nil(value) do
    case display_identifier(value) do
      {:ok, identifier} -> identifier
      {:error, _reason} -> nil
    end
  end

  defp database_id_or_nil(value) do
    case database_id(value) do
      {:ok, database_id} -> database_id
      {:error, _reason} -> nil
    end
  end
end

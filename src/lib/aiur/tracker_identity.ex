defmodule Aiur.TrackerIdentity do
  @moduledoc """
  Versioned, repository-qualified identity for tracker records.

  A display identifier is intentionally retained as a locator, but only a
  `:joinable` identity with a configured repository and opaque provider ID can
  be used as a cross-surface join key.
  """

  @version 1
  @max_provider_id_bytes 512

  @derive {Jason.Encoder, only: [:version, :status, :kind, :owner, :repository, :provider_id, :identifier, :reason]}
  defstruct version: @version,
            status: :unjoinable,
            kind: nil,
            owner: nil,
            repository: nil,
            provider_id: nil,
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
         {:ok, identifier} <- display_identifier(Map.get(issue, "number")) do
      {:ok,
       %__MODULE__{
         version: @version,
         status: :joinable,
         kind: :github,
         owner: owner,
         repository: repository,
         provider_id: provider_id,
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
        {owner, repository} when is_binary(owner) and is_binary(repository) -> {String.trim(owner), String.trim(repository)}
        _ -> {nil, nil}
      end

    %__MODULE__{
      version: @version,
      status: :unjoinable,
      kind: Keyword.get(opts, :kind, :github),
      owner: owner,
      repository: repository,
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
        identifier: identifier
      }) do
    with {:ok, _repository} <- normalize_repository({owner, repository}, :invalid_configured_repository),
         {:ok, _provider_id} <- provider_id(provider_id),
         {:ok, ^identifier} <- display_identifier(identifier) do
      true
    else
      _ -> false
    end
  end

  def joinable?(_identity), do: false

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
    case response_repository(issue) do
      :absent -> :ok
      {:ok, response} -> ensure_same_repository(configured, response)
      :error -> {:error, :repository_mismatch}
    end
  end

  defp response_repository(%{"repository_url" => url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "api.github.com", path: "/repos/" <> path} ->
        case String.split(path, "/", trim: true) do
          [owner, repository] ->
            case normalize_repository({owner, repository}, :repository_mismatch) do
              {:ok, response} -> {:ok, response}
              {:error, _reason} -> :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp response_repository(%{"repository" => %{"owner" => %{"login" => owner}, "name" => repository}}) do
    case normalize_repository({owner, repository}, :repository_mismatch) do
      {:ok, response} -> {:ok, response}
      {:error, _reason} -> :error
    end
  end

  defp response_repository(_issue), do: :absent

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
end

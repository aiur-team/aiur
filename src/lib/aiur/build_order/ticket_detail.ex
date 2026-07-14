defmodule Aiur.BuildOrder.TicketDetail do
  @moduledoc """
  Loads one bounded GitHub issue detail snapshot for a configured repository.

  The request identity is the authority boundary. A display number is used only
  after the identity has passed the configured-repository gate, and the GitHub
  response must prove the same provider node identity before its content is
  accepted.
  """

  alias Aiur.BuildOrder.{Bounded, Lifecycle}
  alias Aiur.{GitHub, SecretRedactor, TrackerIdentity}
  alias Aiur.GitHub.Issues

  @default_max_description_bytes 16_384
  @max_retry_after_seconds 60
  @credential_header_pattern ~r{
    ^\s*
    (?:
      authorization
      | proxy-authorization
      | cookie
      | set-cookie
      | [a-z0-9_-]*(?:token|secret|api[-_]?key|credential)[a-z0-9_-]*
    )
    \s*:
    \s*[^\r\n]*
  }imux
  @structured_credential_pattern ~r/
    (?:
      (?:"|')?
      (?:
        authorization
        | proxy-authorization
        | cookie
        | set-cookie
        | [a-z0-9_-]{0,100}(?:token|secret|api[-_]?key|credential)[a-z0-9_-]{0,100}
      )
      (?:"|')?
      \s*(?::|=>)\s*
      (?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^,\]\}\r\n]+)
    )
    |
    (?:
      \{\s*(?:"|')
      (?:
        authorization
        | proxy-authorization
        | cookie
        | set-cookie
        | [a-z0-9_-]{0,100}(?:token|secret|api[-_]?key|credential)[a-z0-9_-]{0,100}
      )
      (?:"|')\s*,\s*(?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*')\s*\}
    )
  /iux
  @curl_credential_header_pattern ~r/
    (?:-H|--header)\s+(?:"|')
    (?:
      authorization
      | proxy-authorization
      | cookie
      | set-cookie
      | [a-z0-9_-]{0,100}(?:token|secret|api[-_]?key|credential)[a-z0-9_-]{0,100}
    )
    \s*:\s*.*?(?:"|')
  /iux
  @credential_pattern ~r/\b(?:bearer|basic)\s+[^\s,;]+/iu

  defmodule Failure do
    @moduledoc false

    @type kind ::
            :auth
            | :permission
            | :rate_limited
            | :timeout
            | :transport
            | :not_found
            | :schema
            | :validation
            | :provider_identity_mismatch
            | :nonfetchable_repository
            | :configuration
            | :capacity
            | :evicted

    @type t :: %__MODULE__{kind: kind(), retry_after: pos_integer() | nil}

    defstruct [:kind, retry_after: nil]
  end

  defmodule State do
    @moduledoc false

    @type health :: :healthy | :stale | :unavailable

    @type t :: %__MODULE__{
            identity: TrackerIdentity.t(),
            generation: pos_integer() | :unknown,
            health: health(),
            detail: Aiur.BuildOrder.TicketDetail.Snapshot.t() | nil,
            failure: Failure.t() | nil,
            last_success_at: DateTime.t() | nil,
            last_attempt_at: DateTime.t() | nil
          }

    @enforce_keys [:identity, :generation, :health]
    defstruct [:identity, :generation, :health, :detail, :failure, :last_success_at, :last_attempt_at]
  end

  defmodule Snapshot do
    @moduledoc false

    @type t :: %__MODULE__{
            identity: TrackerIdentity.t(),
            title: String.t(),
            description: String.t() | nil,
            lifecycle: Lifecycle.t(),
            url: String.t(),
            created_at: DateTime.t(),
            updated_at: DateTime.t(),
            observed_at: DateTime.t()
          }

    @enforce_keys [:identity, :title, :lifecycle, :url, :created_at, :updated_at, :observed_at]
    defstruct [:identity, :title, :description, :lifecycle, :url, :created_at, :updated_at, :observed_at]
  end

  @type result :: {:ok, Snapshot.t()} | {:error, Failure.t()}

  @spec default_max_description_bytes() :: pos_integer()
  def default_max_description_bytes, do: @default_max_description_bytes

  @doc "Maximum provider Retry-After retained in a public detail failure, in seconds."
  @spec max_retry_after_seconds() :: pos_integer()
  def max_retry_after_seconds, do: @max_retry_after_seconds

  @spec fetch(TrackerIdentity.t(), keyword()) :: result()
  def fetch(identity, opts \\ []) do
    with {:ok, identity, configured_repository} <- fetchable_identity(identity, opts),
         {:ok, raw_issue} <- fetch_issue(identity, configured_repository, opts),
         {:ok, snapshot} <- snapshot(identity, raw_issue, opts) do
      {:ok, snapshot}
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      {:error, reason} -> {:error, failure_from(reason)}
    end
  end

  defp fetch_issue(identity, configured_repository, opts) do
    issue_opts =
      opts
      |> Keyword.take([:request_fun])
      |> Keyword.put(:repository, configured_repository)

    Issues.fetch_issue_raw(identity.identifier, issue_opts)
  end

  @spec fetchable_identity(TrackerIdentity.t(), keyword()) ::
          {:ok, TrackerIdentity.t(), TrackerIdentity.repository()} | {:error, Failure.t()}
  def fetchable_identity(identity, opts \\ []) do
    if TrackerIdentity.joinable?(identity) and identity.kind == :github do
      configured_identity(identity, opts)
    else
      {:error, %Failure{kind: :nonfetchable_repository}}
    end
  end

  @spec snapshot(TrackerIdentity.t(), map(), keyword()) :: {:ok, Snapshot.t()} | {:error, Failure.t()}
  def snapshot(identity, raw_issue, opts \\ [])

  def snapshot(identity, raw_issue, opts) when is_map(raw_issue) do
    max_description_bytes = description_limit(opts)

    with true <- TrackerIdentity.joinable?(identity),
         :github <- identity.kind,
         :ok <- issue_response?(raw_issue),
         :ok <- matching_response_repository?(identity, raw_issue),
         :ok <- matching_provider_identity?(identity, raw_issue),
         :ok <- matching_number?(identity, raw_issue),
         {:ok, title} <- title(raw_issue["title"]),
         {:ok, body} <- required_body(raw_issue),
         {:ok, description} <- description(body, max_description_bytes),
         {:ok, url} <- configured_issue_url(raw_issue["html_url"], identity),
         {:ok, lifecycle} <- lifecycle(raw_issue["state"], raw_issue["state_reason"]),
         {:ok, created_at} <- timestamp(raw_issue["created_at"]),
         {:ok, updated_at} <- timestamp(raw_issue["updated_at"]),
         {:ok, observed_at} <- observed_at(opts) do
      {:ok,
       %Snapshot{
         identity: identity,
         title: title,
         description: description,
         lifecycle: lifecycle,
         url: url,
         created_at: created_at,
         updated_at: updated_at,
         observed_at: observed_at
       }}
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      :schema -> {:error, %Failure{kind: :schema}}
      :provider_identity_mismatch -> {:error, %Failure{kind: :provider_identity_mismatch}}
      _ -> {:error, %Failure{kind: :validation}}
    end
  end

  def snapshot(_identity, _raw_issue, _opts), do: {:error, %Failure{kind: :schema}}

  defp configured_repository(opts) do
    opts
    |> Keyword.get_lazy(:configured_repo, &GitHub.Config.configured_repo/0)
    |> configured_repository_result()
  end

  defp configured_identity(identity, opts) do
    with {:ok, configured_repository} <- configured_repository(opts),
         :ok <- valid_repository_components(identity),
         true <- same_repository?(identity, configured_repository) do
      {:ok, identity, configured_repository}
    else
      :invalid_repository_component -> {:error, %Failure{kind: :nonfetchable_repository}}
      false -> {:error, %Failure{kind: :nonfetchable_repository}}
      {:error, %Failure{} = failure} -> {:error, failure}
    end
  end

  defp configured_repository_result({:ok, repository}), do: configured_repository_result(repository)

  defp configured_repository_result({owner, repository}) when is_binary(owner) and is_binary(repository) do
    with {:ok, owner} <- Bounded.github_repository_component(owner),
         {:ok, repository} <- Bounded.github_repository_component(repository) do
      {:ok, {owner, repository}}
    else
      _ -> {:error, %Failure{kind: :configuration}}
    end
  end

  defp configured_repository_result(_repository), do: {:error, %Failure{kind: :configuration}}

  defp same_repository?(%TrackerIdentity{owner: owner, repository: repository}, {configured_owner, configured_repository}) do
    String.downcase(owner) == String.downcase(configured_owner) and
      String.downcase(repository) == String.downcase(configured_repository)
  end

  defp valid_repository_components(%TrackerIdentity{owner: owner, repository: repository}) do
    with {:ok, _owner} <- Bounded.github_repository_component(owner),
         {:ok, _repository} <- Bounded.github_repository_component(repository) do
      :ok
    else
      _ -> :invalid_repository_component
    end
  end

  defp issue_response?(%{"pull_request" => pull_request}) when not is_nil(pull_request), do: {:error, %Failure{kind: :schema}}
  defp issue_response?(_raw_issue), do: :ok

  defp matching_response_repository?(identity, raw_issue) do
    case Map.fetch(raw_issue, "repository_url") do
      :error -> :ok
      {:ok, repository_url} -> configured_api_repository_url(repository_url, identity)
    end
  end

  defp configured_api_repository_url(
         repository_url,
         %TrackerIdentity{owner: owner, repository: repository}
       )
       when is_binary(repository_url) do
    with %URI{scheme: "https", host: "api.github.com", path: "/repos/" <> path} <- URI.parse(repository_url),
         [response_owner, response_repository] <- String.split(path, "/", trim: true),
         true <- String.downcase(response_owner) == String.downcase(owner),
         true <- String.downcase(response_repository) == String.downcase(repository) do
      :ok
    else
      _ -> :provider_identity_mismatch
    end
  end

  defp configured_api_repository_url(_repository_url, _identity), do: :provider_identity_mismatch

  defp matching_provider_identity?(%TrackerIdentity{provider_id: provider_id}, %{"node_id" => node_id})
       when node_id == provider_id,
       do: :ok

  defp matching_provider_identity?(_identity, _raw_issue), do: :provider_identity_mismatch

  defp matching_number?(%TrackerIdentity{identifier: identifier}, %{"number" => number}) when is_integer(number) and number > 0 do
    if Integer.to_string(number) == identifier, do: :ok, else: :provider_identity_mismatch
  end

  defp matching_number?(_identity, _raw_issue), do: :provider_identity_mismatch

  defp title(value) when is_binary(value) do
    with {:ok, sanitized} <- sanitize(value, 512),
         {:ok, _} <- Bounded.title(sanitized) do
      {:ok, sanitized}
    else
      _ -> {:error, %Failure{kind: :validation}}
    end
  end

  defp title(_value), do: {:error, %Failure{kind: :validation}}

  defp description(nil, _max_bytes), do: {:ok, nil}
  defp description("", _max_bytes), do: {:ok, nil}

  defp description(value, max_bytes) when is_binary(value) and is_integer(max_bytes) and max_bytes > 0 do
    case sanitize(value, max_bytes) do
      {:ok, sanitized} -> {:ok, if(sanitized == "", do: nil, else: sanitized)}
      :error -> {:error, %Failure{kind: :validation}}
    end
  end

  defp description(_value, _max_bytes), do: {:error, %Failure{kind: :validation}}

  defp required_body(raw_issue) do
    case Map.fetch(raw_issue, "body") do
      {:ok, body} -> {:ok, body}
      :error -> :schema
    end
  end

  defp description_limit(opts) do
    case Keyword.get(opts, :max_description_bytes, @default_max_description_bytes) do
      bytes when is_integer(bytes) and bytes > 0 and bytes <= @default_max_description_bytes -> bytes
      _ -> @default_max_description_bytes
    end
  end

  defp lifecycle(state, reason) do
    case Lifecycle.from_github(state, reason) do
      %Lifecycle{state: :unknown} -> {:error, %Failure{kind: :validation}}
      lifecycle -> {:ok, lifecycle}
    end
  end

  defp sanitize(value, limit) when is_binary(value) and is_integer(limit) and limit > 0 do
    if String.valid?(value) do
      sanitized =
        value
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
        |> SecretRedactor.redact()
        |> redact_credentials()
        |> redact_local_paths()

      if byte_size(sanitized) <= limit, do: {:ok, sanitized}, else: :error
    else
      :error
    end
  end

  defp redact_credentials(value) do
    value = Regex.replace(@curl_credential_header_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@structured_credential_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@credential_header_pattern, value, "[REDACTED:credential]")
    Regex.replace(@credential_pattern, value, "[REDACTED:credential]")
  end

  defp redact_local_paths(value) do
    value = Regex.replace(~r{(?:~|/)(?:Users|home|private|tmp)/[^\s]+}u, value, "[REDACTED:local_path]")
    Regex.replace(~r{[A-Za-z]:\\[^\s]+}u, value, "[REDACTED:local_path]")
  end

  defp configured_issue_url(value, %TrackerIdentity{owner: owner, repository: repository, identifier: identifier}) do
    with {:ok, url} <- Bounded.github_url(value),
         %URI{path: path} <- URI.parse(url),
         [url_owner, url_repository, "issues", ^identifier] <- String.split(path, "/", trim: true),
         true <- String.downcase(url_owner) == String.downcase(owner),
         true <- String.downcase(url_repository) == String.downcase(repository) do
      {:ok, url}
    else
      _ -> {:error, %Failure{kind: :validation}}
    end
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      _ -> {:error, %Failure{kind: :validation}}
    end
  end

  defp timestamp(_value), do: {:error, %Failure{kind: :validation}}

  defp observed_at(opts) do
    case Keyword.get_lazy(opts, :now, &DateTime.utc_now/0) do
      %DateTime{} = timestamp -> {:ok, timestamp}
      _ -> {:error, %Failure{kind: :validation}}
    end
  end

  defp failure_from({:github, :auth, _detail}), do: %Failure{kind: :auth}
  defp failure_from({:github, :rate_limited, detail}), do: %Failure{kind: :rate_limited, retry_after: bounded_retry_after(detail[:retry_after])}
  defp failure_from({:github, :timeout, _detail}), do: %Failure{kind: :timeout}
  defp failure_from({:github, _kind, %{status: 404}}), do: %Failure{kind: :not_found}
  defp failure_from({:github, _kind, %{status: 403}}), do: %Failure{kind: :permission}
  defp failure_from({:github, _kind, _detail}), do: %Failure{kind: :transport}
  defp failure_from(:invalid_github_issue_response), do: %Failure{kind: :schema}
  defp failure_from(_reason), do: %Failure{kind: :transport}

  defp bounded_retry_after(value) when is_integer(value) and value > 0, do: min(value, @max_retry_after_seconds)
  defp bounded_retry_after(_value), do: nil
end

defmodule Aiur.BuildOrder.TicketDetail.Normalizer do
  @moduledoc false

  alias Aiur.BuildOrder.{Bounded, Lifecycle}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Sanitizer, Snapshot}
  alias Aiur.TrackerIdentity

  @default_max_description_bytes 16_384
  @max_retry_after_seconds 60

  @spec default_max_description_bytes() :: pos_integer()
  def default_max_description_bytes, do: @default_max_description_bytes

  @spec max_retry_after_seconds() :: pos_integer()
  def max_retry_after_seconds, do: @max_retry_after_seconds

  @spec snapshot(TrackerIdentity.t(), map(), keyword()) :: {:ok, Snapshot.t()} | {:error, Failure.t()}
  def snapshot(%TrackerIdentity{} = identity, raw_issue, opts) when is_map(raw_issue) do
    with {:ok, _identifier} <- Bounded.github_issue_identifier(identity.identifier),
         true <- TrackerIdentity.joinable?(identity),
         :github <- identity.kind,
         :ok <- issue_response?(raw_issue),
         :ok <- matching_response_repository?(identity, raw_issue),
         :ok <- matching_provider_identity?(identity, raw_issue),
         :ok <- matching_number?(identity, raw_issue),
         {:ok, title} <- title(raw_issue["title"]),
         {:ok, body} <- required_body(raw_issue),
         {:ok, description} <- description(body, description_limit(opts)),
         {:ok, url} <- configured_issue_url(raw_issue["html_url"], identity),
         {:ok, lifecycle} <- required_lifecycle(raw_issue),
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

  @spec failure_from(term()) :: Failure.t()
  def failure_from({:github, :auth, _detail}), do: %Failure{kind: :auth}

  def failure_from({:github, :rate_limited, detail}),
    do: %Failure{kind: :rate_limited, retry_after: bounded_retry_after(detail[:retry_after])}

  def failure_from({:github, :timeout, _detail}), do: %Failure{kind: :timeout}
  def failure_from(:missing_github_token), do: %Failure{kind: :auth}
  def failure_from(:github_issue_response_too_large), do: %Failure{kind: :schema}
  def failure_from({:github, _kind, %{status: 404}}), do: %Failure{kind: :not_found}
  def failure_from({:github, _kind, %{status: 403}}), do: %Failure{kind: :permission}
  def failure_from({:github, _kind, _detail}), do: %Failure{kind: :transport}
  def failure_from(:invalid_github_issue_response), do: %Failure{kind: :schema}
  def failure_from(_reason), do: %Failure{kind: :transport}

  defp issue_response?(%{"pull_request" => pull_request}) when not is_nil(pull_request), do: :schema
  defp issue_response?(_raw_issue), do: :ok

  defp matching_response_repository?(identity, raw_issue) do
    case Map.fetch(raw_issue, "repository_url") do
      :error -> :ok
      {:ok, repository_url} -> configured_api_repository_url(repository_url, identity)
    end
  end

  defp configured_api_repository_url(repository_url, %TrackerIdentity{owner: owner, repository: repository})
       when is_binary(repository_url) do
    with %URI{scheme: "https", host: "api.github.com", port: 443, userinfo: nil, query: nil, fragment: nil, path: path} <-
           URI.parse(repository_url),
         true <- String.starts_with?(repository_url, "https://api.github.com/"),
         ["repos", response_owner, response_repository] <- String.split(path || "", "/", trim: true),
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
    with {:ok, sanitized} <- Sanitizer.sanitize(value, 512),
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
    case Sanitizer.sanitize(value, max_bytes) do
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

  defp required_lifecycle(raw_issue) do
    with {:ok, state} <- Map.fetch(raw_issue, "state"),
         {:ok, reason} <- Map.fetch(raw_issue, "state_reason") do
      lifecycle = Lifecycle.from_github(state, reason)

      if Lifecycle.valid?(lifecycle) do
        {:ok, lifecycle}
      else
        {:error, %Failure{kind: :validation}}
      end
    else
      :error -> :schema
    end
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

  defp bounded_retry_after(value) when is_integer(value) and value > 0, do: min(value, @max_retry_after_seconds)
  defp bounded_retry_after(_value), do: nil
end

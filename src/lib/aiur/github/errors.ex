defmodule Aiur.GitHub.Errors do
  @moduledoc """
  GitHub transport, HTTP, and rate-limit error taxonomy.
  """

  alias Aiur.GitHub.GraphQLErrors

  @typedoc """
  The error classification produced by `classify_error/1`. Executors must be
  able to tell these apart to fix flaky GitHub access (#617): a DNS outage and
  an expired token need entirely different remediation.
  """
  @type classification ::
          :dns | :timeout | :tls | :transport | :auth | :permission | :rate_limited | :http

  @doc """
  Classifies a GitHub transport failure or HTTP response into the structured
  error taxonomy `{:github, classification, detail}`.

  Accepts either:

    * `{:error, reason}` — a transport failure, where `reason` is a
      `Req.TransportError`/`Mint.TransportError` (or bare reason). DNS
      (`:nxdomain`) → `:dns`; connectivity (`:timeout`/`:closed`/`:econnrefused`
      …) → `:timeout`; TLS alerts → `:tls`; anything else → `:transport`.
    * an HTTP response map `%{status: ...}` — 401 → `:auth`; a 403 carrying a
      rate-limit signal → `:rate_limited`; any other status → `:http`.

  `detail` is a map (`%{reason: ...}` for transport, `%{status: ...}` for HTTP,
  plus `:retry_after`/`:poll_interval` for rate-limit) so callers can both
  pattern-match the classification and recover the specifics.
  """
  @spec classify_error({:error, term()} | map()) :: {:github, classification(), map()}
  def classify_error({:error, reason}), do: classify_transport(reason)

  def classify_error(%{status: status} = response) when is_integer(status) do
    classify_status(status, response)
  end

  @spec classify_transport(term()) :: {:github, classification(), map()}
  def classify_transport(%{__struct__: struct, reason: reason})
      when struct in [Req.TransportError, Mint.TransportError] do
    classify_transport_reason(reason)
  end

  def classify_transport(reason), do: classify_transport_reason(reason)

  @spec classify_transport_reason(term()) :: {:github, classification(), map()}
  def classify_transport_reason(:nxdomain), do: {:github, :dns, %{reason: :nxdomain}}

  def classify_transport_reason(reason)
      when reason in [:timeout, :closed, :econnrefused, :ehostunreach, :enetunreach, :econnreset],
      do: {:github, :timeout, %{reason: reason}}

  def classify_transport_reason(reason)
      when reason in [:protocol_not_negotiated],
      do: {:github, :tls, %{reason: reason}}

  def classify_transport_reason({tag, _} = reason)
      when tag in [:tls_alert, :bad_alpn_protocol, :ssl_error],
      do: {:github, :tls, %{reason: reason}}

  def classify_transport_reason(reason), do: {:github, :transport, %{reason: reason}}

  @spec classify_status(integer(), map()) :: {:github, classification(), map()}
  def classify_status(401, response), do: {:github, :auth, %{status: 401, message: response_message(response)}}

  def classify_status(403, response) do
    if rate_limited_response?(response, :unknown) do
      {:github, :rate_limited,
       %{
         status: 403,
         retry_after: retry_after(response),
         reset_at: rate_limit_reset(response),
         poll_interval: rate_limit_poll_interval(response)
       }}
    else
      {:github, :http, %{status: 403}}
    end
  end

  def classify_status(429, response) do
    {:github, :rate_limited,
     %{
       status: 429,
       retry_after: retry_after(response),
       reset_at: rate_limit_reset(response),
       poll_interval: rate_limit_poll_interval(response)
     }}
  end

  def classify_status(status, _response), do: {:github, :http, %{status: status}}

  @spec github_status_error(map()) :: {:github, classification(), map()}
  def github_status_error(%{status: _status} = response), do: classify_error(response)

  @doc "Classifies GraphQL responses with planning-graph provider evidence."
  @spec github_graph_status_error(map()) :: {:github, classification(), map()}
  def github_graph_status_error(%{status: status} = response) do
    detail = Map.put(rate_limit_observation(response), :status, status)
    {:github, graph_status_classification(status, response), detail}
  end

  defp graph_status_classification(401, _response), do: :auth
  defp graph_status_classification(429, _response), do: :rate_limited

  defp graph_status_classification(403, response) do
    if rate_limited_response?(response, :unknown), do: :rate_limited, else: :permission
  end

  defp graph_status_classification(_status, _response), do: :http

  @spec graphql_error(map()) :: {:github, :rate_limited | :permission, map()} | :graphql_partial
  defdelegate graphql_error(response), to: GraphQLErrors

  @spec response_message(map()) :: String.t() | nil
  def response_message(%{body: %{"message" => message}}) when is_binary(message), do: message
  def response_message(_response), do: nil

  @spec retry_after(map()) :: pos_integer() | nil
  defdelegate retry_after(response), to: GraphQLErrors

  @spec rate_limit_poll_interval(map()) :: pos_integer() | nil
  defdelegate rate_limit_poll_interval(response), to: GraphQLErrors

  @spec rate_limited_response?(map(), atom()) :: boolean()
  defdelegate rate_limited_response?(response, endpoint), to: GraphQLErrors

  @spec rate_limit_remaining(map()) :: integer() | nil
  defdelegate rate_limit_remaining(response), to: GraphQLErrors

  @spec rate_limit_reset(map()) :: String.t() | nil
  defdelegate rate_limit_reset(response), to: GraphQLErrors

  @spec rate_limit_observation(map()) :: map()
  defdelegate rate_limit_observation(response), to: GraphQLErrors

  @spec rate_limit_body_remaining(map()) :: integer() | nil
  defdelegate rate_limit_body_remaining(response), to: GraphQLErrors

  @spec rate_limit_message?(term()) :: boolean()
  defdelegate rate_limit_message?(body), to: GraphQLErrors

  @spec retryable_github_error?(term()) :: boolean()
  def retryable_github_error?({:github, kind, _detail})
      when kind in [:dns, :timeout, :tls, :transport, :rate_limited],
      do: true

  def retryable_github_error?({:github, :http, %{status: status}}) when status in 500..599, do: true

  def retryable_github_error?(_reason), do: false
end

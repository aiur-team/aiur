defmodule Aiur.GitHub.Budget.ResponseLimits do
  @moduledoc false

  alias Aiur.GitHub.{Budget, GraphQLErrors, Transport}
  require Logger

  @spec limit_hold(map(), list()) :: term()
  def limit_hold(response, headers) do
    cond do
      GraphQLErrors.secondary_rate_limited_response?(response) -> {:token, retry_after_ms(response)}
      remaining(headers) == 0 -> primary_limit_hold(headers, response)
      true -> :none
    end
  end

  defp primary_limit_hold(headers, response) do
    case reset_after_ms(headers) do
      delay when is_integer(delay) and delay > 0 -> {:resource, delay}
      _missing -> {:token, retry_after_ms(response)}
    end
  end

  defp retry_after_ms(response) do
    case GraphQLErrors.retry_after(response) do
      seconds when is_integer(seconds) and seconds > 0 -> min(seconds * 1_000, 60 * 60 * 1_000)
      _missing -> 60 * 1_000
    end
  end

  defp reset_after_ms(headers) do
    headers
    |> Transport.header("x-ratelimit-reset")
    |> reset_delay_ms()
  end

  defp reset_delay_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {reset, ""} -> reset_delay_ms(reset)
      _invalid -> nil
    end
  end

  defp reset_delay_ms(value) when is_integer(value), do: max(value * 1_000 - System.system_time(:millisecond), 1)
  defp reset_delay_ms(_missing), do: nil

  defp remaining(headers) do
    case Transport.header(headers, "x-ratelimit-remaining") do
      value when is_binary(value) -> parse_integer(value)
      value when is_integer(value) -> value
      _missing -> nil
    end
  end

  # A resource hold is only ever issued for a pool the request actually targets
  # or that the response names as one we model. The response's
  # `x-ratelimit-resource` header is authoritative when it names `core`,
  # `graphql`, or `search`; an absent header falls back to the request's own
  # pool; a header naming any other pool (which GitHub uses for
  # `integration_manifest`, `code_scanning_upload`, …) resolves to `nil` so the
  # caller skips the hold instead of misattributing that pool's exhaustion to
  # `core` (#2409).
  @spec response_resource(list(), map()) :: String.t() | nil
  def response_resource(headers, request) do
    case Transport.header(headers, "x-ratelimit-resource") do
      resource when resource in ["core", "graphql", "search"] -> resource
      nil -> Budget.request_resource(request)
      _other_pool -> nil
    end
  end

  # Acceptance #2409: a hold decision must say which ceiling it hit and what was
  # measured. Log every issued resource hold with the observed remaining (0 is
  # what triggered it), the ceiling (`x-ratelimit-limit`), and the reset so a
  # post-incident read of the daemon log can tell a real exhaustion from a
  # misattribution without guessing.
  @spec log_resource_hold(String.t(), list(), map(), integer()) :: :ok
  def log_resource_hold(resource, headers, request, delay_ms) do
    Logger.warning(
      "github_budget_resource_hold resource=#{resource} " <>
        "remaining=#{inspect(remaining(headers))} " <>
        "limit=#{inspect(nonnegative_parse(Transport.header(headers, "x-ratelimit-limit")))} " <>
        "reset_after_ms=#{delay_ms} " <>
        "x_ratelimit_reset=#{inspect(Transport.header(headers, "x-ratelimit-reset"))} " <>
        "url=#{inspect(Map.get(request, :url))}"
    )
  end

  defp nonnegative_parse(nil), do: nil
  defp nonnegative_parse(value) when is_binary(value), do: parse_integer(value)
  defp nonnegative_parse(value) when is_integer(value), do: value

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  @spec atomize_snapshot(term()) :: map()
  def atomize_snapshot(%{"cooldown_until_ms" => cooldown, "inflight" => inflight, "admissions" => admissions}) do
    %{
      cooldown_until_ms: cooldown,
      inflight: inflight,
      admissions:
        Enum.map(admissions, fn admission ->
          %{
            endpoint_family: admission["endpoint_family"],
            resource: admission["resource"],
            admitted_at_ms: admission["admitted_at_ms"],
            # `billable = false` is a reconciled `304`; `billable_reason`
            # records why the broker stopped billing the row (`"304"`) so the
            # running system can verify reconciliation happened and tell it
            # apart from any other unbilled state instead of reading a bare
            # flag.
            billable: Map.get(admission, "billable", true),
            billable_reason: Map.get(admission, "billable_reason")
          }
        end)
    }
  end

  def atomize_snapshot(_snapshot), do: %{cooldown_until_ms: 0, inflight: %{}, admissions: []}

  @spec atomize_actor(term()) :: map()
  def atomize_actor(actor) when is_map(actor) do
    %{
      token_key: Map.get(actor, "token_key", ""),
      consumer_key: Map.get(actor, "consumer_key", ""),
      consumer_label: Map.get(actor, "consumer_label", ""),
      core: atomize_usage_figure(Map.get(actor, "core")),
      graphql: atomize_usage_figure(Map.get(actor, "graphql")),
      search: atomize_usage_figure(Map.get(actor, "search"))
    }
  end

  def atomize_actor(_actor),
    do: %{
      token_key: "",
      consumer_key: "",
      consumer_label: "",
      core: atomize_usage_figure(nil),
      graphql: atomize_usage_figure(nil),
      search: atomize_usage_figure(nil)
    }

  @spec atomize_usage_figure(term()) :: map()
  def atomize_usage_figure(figure) when is_map(figure) do
    %{
      used: Map.get(figure, "used", 0),
      limit: Map.get(figure, "limit", 0),
      reset_at_ms: Map.get(figure, "reset_at_ms")
    }
  end

  def atomize_usage_figure(_figure), do: %{used: 0, limit: 0, reset_at_ms: nil}
end

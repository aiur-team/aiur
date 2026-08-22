defmodule Aiur.GitHub.GraphQLErrors do
  @moduledoc false

  alias Aiur.GitHub.Transport

  @spec graphql_error(map()) :: {:github, :rate_limited | :permission, map()} | :graphql_partial
  def graphql_error(response) do
    case graphql_error_classification(response) do
      nil -> :graphql_partial
      classification -> graphql_provider_error(classification, response)
    end
  end

  @spec retry_after(map()) :: pos_integer() | nil
  def retry_after(%{headers: headers}) do
    case Transport.header(headers, "retry-after") do
      value when is_binary(value) -> positive_integer(value)
      _ -> nil
    end
  end

  def retry_after(_response), do: nil

  @spec rate_limit_poll_interval(map()) :: pos_integer() | nil
  def rate_limit_poll_interval(%{headers: headers}) do
    case Transport.header(headers, "x-poll-interval") do
      value when is_binary(value) -> positive_integer(value)
      _ -> nil
    end
  end

  def rate_limit_poll_interval(_response), do: nil

  @spec rate_limited_response?(map(), atom()) :: boolean()
  def rate_limited_response?(response, endpoint) do
    Map.get(response, :status) == 429 or
      rate_limit_remaining(response) == 0 or
      (endpoint == :rate_limit and rate_limit_body_remaining(response) == 0) or
      rate_limit_message?(Map.get(response, :body))
  end

  @spec rate_limit_remaining(map()) :: integer() | nil
  def rate_limit_remaining(%{headers: headers}) do
    case Transport.header(headers, "x-ratelimit-remaining") do
      value when is_binary(value) -> integer(value)
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  def rate_limit_remaining(_response), do: nil

  @spec rate_limit_reset(map()) :: String.t() | nil
  def rate_limit_reset(%{headers: headers}) do
    with value when is_binary(value) <- Transport.header(headers, "x-ratelimit-reset"),
         {unix, _} <- Integer.parse(value),
         {:ok, datetime} <- DateTime.from_unix(unix) do
      DateTime.to_iso8601(datetime)
    else
      _ -> nil
    end
  end

  def rate_limit_reset(_response), do: nil

  @spec rate_limit_observation(map()) :: map()
  def rate_limit_observation(response) when is_map(response) do
    %{
      remaining: rate_limit_remaining(response),
      reset_at: rate_limit_reset(response),
      retry_after: retry_after(response),
      poll_interval: rate_limit_poll_interval(response)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def rate_limit_observation(_response), do: %{}

  @spec rate_limit_body_remaining(map()) :: integer() | nil
  def rate_limit_body_remaining(%{body: %{"resources" => %{"core" => %{"remaining" => remaining}}}})
      when is_integer(remaining),
      do: remaining

  def rate_limit_body_remaining(%{body: %{"rate" => %{"remaining" => remaining}}})
      when is_integer(remaining),
      do: remaining

  def rate_limit_body_remaining(_response), do: nil

  @spec rate_limit_message?(term()) :: boolean()
  def rate_limit_message?(%{"message" => message}) when is_binary(message) do
    message
    |> String.downcase()
    |> String.contains?("rate limit")
  end

  def rate_limit_message?(_body), do: false

  @spec secondary_rate_limited_response?(map()) :: boolean()
  def secondary_rate_limited_response?(%{status: status} = response) when status in [403, 429] do
    retry_after(response) != nil or
      secondary_rate_limit_message?(Map.get(response, :body)) or
      (rate_limited_response?(response, :unknown) and rate_limit_remaining(response) != 0)
  end

  def secondary_rate_limited_response?(_response), do: false

  defp secondary_rate_limit_message?(%{"message" => message}) when is_binary(message) do
    normalized = String.downcase(message)
    String.contains?(normalized, "secondary rate limit") or String.contains?(normalized, "abuse detection")
  end

  defp secondary_rate_limit_message?(_body), do: false

  defp graphql_provider_error(classification, response) do
    detail = rate_limit_observation(response) |> Map.put(:status, Map.get(response, :status))
    {:github, classification, detail}
  end

  defp graphql_error_classification(response) do
    cond do
      graphql_error_code?(response, "RATE_LIMITED") -> :rate_limited
      graphql_error_code?(response, "FORBIDDEN") -> :permission
      rate_limited_response?(response, :unknown) or graphql_error_message?(response, "rate limit") -> :rate_limited
      graphql_error_message?(response, "resource not accessible") -> :permission
      true -> nil
    end
  end

  defp graphql_errors(%{body: %{"errors" => errors}}) when is_list(errors), do: errors
  defp graphql_errors(_response), do: []

  defp graphql_error_code?(response, code),
    do: Enum.any?(graphql_errors(response), &(is_map(&1) and code in graphql_error_codes(&1)))

  defp graphql_error_message?(response, message),
    do: Enum.any?(graphql_errors(response), &(is_map(&1) and String.contains?(graphql_error_message(&1), message)))

  defp graphql_error_codes(error) do
    [Map.get(error, "type"), Map.get(error, "code"), graphql_extension_code(error)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.upcase/1)
  end

  defp graphql_extension_code(%{"extensions" => %{} = extensions}), do: Map.get(extensions, "code")
  defp graphql_extension_code(_error), do: nil

  defp graphql_error_message(error) do
    case Map.get(error, "message") do
      message when is_binary(message) -> String.downcase(message)
      _ -> ""
    end
  end

  defp positive_integer(value) do
    case Integer.parse(value) do
      {number, _rest} when number > 0 -> number
      _ -> nil
    end
  end

  defp integer(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      _ -> nil
    end
  end
end

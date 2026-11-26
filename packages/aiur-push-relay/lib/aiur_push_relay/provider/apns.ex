defmodule AiurPushRelay.Provider.Apns do
  @moduledoc "APNs HTTP/2 adapter; logs only allowlisted provider reason codes."
  @behaviour AiurPushRelay.Provider
  alias AiurPushRelay.Provider.Apns.{Jwt, Request}
  require Logger
  @backoff 5_000

  @impl true
  def deliver(row, envelope) do
    deliver(row, envelope, Application.fetch_env!(:aiur_push_relay, :apns))
  end

  @spec deliver(map(), map(), keyword()) ::
          :ok | {:gone, String.t()} | {:retry, non_neg_integer()} | {:error, term()}
  def deliver(row, envelope, opts) do
    token = Jwt.token(Keyword.fetch!(opts, :jwt))
    send_request(row, envelope, opts, token, true)
  end

  defp send_request(row, envelope, opts, token, refresh?) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, request} <- Request.build(row, envelope, Keyword.fetch!(opts, :pins), token, now) do
      transport = Keyword.get(opts, :transport, &Finch.request(&1, AiurPushRelay.ApnsFinch))

      case transport.(request) do
        {:ok, %{status: 403, body: body}} ->
          if reason(body) == "ExpiredProviderToken" do
            if refresh? do
              new_token = Jwt.token(Keyword.fetch!(opts, :jwt), token)
              send_request(row, envelope, opts, new_token, false)
            else
              {:retry, @backoff}
            end
          else
            failure(403, body)
          end

        {:ok, %{status: status, body: body}} ->
          failure(status, body)

        {:error, _} ->
          {:retry, @backoff}
      end
    end
  end

  defp failure(200, _), do: :ok
  defp failure(410, body), do: {:gone, reason(body)}

  defp failure(400, body) do
    case reason(body) do
      "BadDeviceToken" -> {:gone, "BadDeviceToken"}
      reason -> reject(reason)
    end
  end

  defp failure(429, _), do: {:retry, 60_000}
  defp failure(status, _) when status >= 500, do: {:retry, @backoff}
  defp failure(_, body), do: reject(reason(body))

  defp reject(reason) do
    Logger.warning("apns_rejected", reason: reason)
    {:error, reason}
  end

  # Never reflect arbitrary response content into logs or result reasons.
  defp reason(body) do
    known =
      ~w(BadDeviceToken Unregistered ExpiredProviderToken BadTopic DeviceTokenNotForTopic
      TopicDisallowed InvalidProviderToken MissingProviderToken BadPriority BadExpirationDate
      BadCollapseId PayloadEmpty PayloadTooLarge TooManyRequests Forbidden TooManyProviderTokenUpdates)

    case Jason.decode(body) do
      {:ok, %{"reason" => reason}} -> if reason in known, do: reason, else: "Unknown"
      _ -> "Unknown"
    end
  end
end

defmodule AiurPushRelay.Provider.Apns.Request do
  @moduledoc "Builds APNs alert requests using only the publisher's pinned fallback."

  @spec build(map(), map(), map(), String.t(), integer()) ::
          {:ok, Finch.Request.t()} | {:error, atom()}
  def build(row, envelope, pins, token, now) do
    with {:ok, pin} <- Map.fetch(pins, row.app_topic) do
      body =
        Jason.encode!(%{
          "aps" => %{"alert" => pin, "mutable-content" => 1},
          "s" => envelope["sealed"],
          "k" => envelope["kid"],
          "v" => 1
        })

      if byte_size(body) > 4096 do
        {:error, :payload_too_large}
      else
        headers = [
          {"authorization", "bearer " <> token},
          {"content-type", "application/json"},
          {"apns-topic", row.app_topic},
          {"apns-push-type", "alert"},
          {"apns-priority", if(envelope["push_class"] == "alert_high", do: "10", else: "5")},
          {"apns-expiration", expiration(envelope["ttl_s"], now)}
        ]

        headers =
          if envelope["collapse_token"],
            do: [{"apns-collapse-id", envelope["collapse_token"]} | headers],
            else: headers

        host =
          case row.environment do
            "sandbox" -> "api.sandbox.push.apple.com"
            "production" -> "api.push.apple.com"
          end

        url = "https://#{host}/3/device/" <> URI.encode(row.push_token, &URI.char_unreserved?/1)
        {:ok, Finch.build(:post, url, headers, body)}
      end
    else
      :error -> {:error, :unknown_topic}
    end
  end

  defp expiration(0, _), do: "0"
  defp expiration(ttl, now), do: Integer.to_string(now + ttl)
end

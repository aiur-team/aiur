defmodule AiurPushRelay.Handles do
  @moduledoc "Handle creation, topic validation, and constant-time bearer authentication."
  alias AiurPushRelay.Store

  def create(store, pins, params) do
    with :ok <- validate(params, pins) do
      handle = "h_" <> Base.encode32(:crypto.strong_rand_bytes(16), padding: false)
      secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      row = %{
        handle: handle,
        platform: params["platform"],
        push_token: params["push_token"],
        app_topic: params["app_topic"],
        environment: params["environment"],
        send_secret_sha256: :crypto.hash(:sha256, secret),
        created_at: System.system_time(:second)
      }

      with :ok <- Store.call(store, :create, [row]) do
        {:ok, %{handle: handle, send_secret: secret}}
      end
    end
  end

  def authenticate(store, handle, secret) do
    with :ok <- valid_handle(handle),
         {:ok, row} <- Store.call(store, :get, [handle]),
         true <- Plug.Crypto.secure_compare(row.send_secret_sha256, :crypto.hash(:sha256, secret)) do
      {:ok, row}
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  defp valid_handle(handle) when is_binary(handle) and byte_size(handle) in 1..64, do: :ok
  defp valid_handle(_), do: {:error, :schema}

  defp validate(params, pins) when is_map(params) do
    valid =
      params["platform"] in ["apns", "fcm"] and
        params["environment"] in ["production", "sandbox"] and
        is_binary(params["push_token"]) and byte_size(params["push_token"]) in 1..4096 and
        Map.has_key?(pins, params["app_topic"])

    if valid, do: :ok, else: {:error, :schema}
  end

  defp validate(_, _), do: {:error, :schema}
end

defmodule AiurPushRelay.Provider.Fcm do
  @moduledoc "Firebase Cloud Messaging HTTP v1 data-only provider."
  @behaviour AiurPushRelay.Provider

  @max_payload_bytes 4096
  @default_request_fun &Req.post/1

  def configure do
    if Process.whereis(AiurPushRelay.Provider.Supervisor) == nil do
      {AiurPushRelay.Provider.Disabled, "unconfigured"}
    else
      configure_from_environment()
    end
  end

  defp configure_from_environment do
    case System.get_env("AIUR_RELAY_FCM_SERVICE_ACCOUNT_FILE") do
      path when is_binary(path) and path != "" ->
        with {:ok, account} <- AiurPushRelay.Provider.Fcm.Auth.load(path),
             {:ok, auth_pid} <- start_auth(account) do
          {:ok, account, auth_pid}
        else
          _ -> {AiurPushRelay.Provider.Disabled, "degraded"}
        end

      _ ->
        {AiurPushRelay.Provider.Disabled, "unconfigured"}
    end
  end

  def start_auth(account, opts \\ []) do
    request_fun =
      Keyword.get(
        opts,
        :request_fun,
        Application.get_env(:aiur_push_relay, :fcm_token_request_fun, @default_request_fun)
      )

    case DynamicSupervisor.start_child(
           Keyword.get(opts, :supervisor, AiurPushRelay.Provider.Supervisor),
           {AiurPushRelay.Provider.Fcm.Auth,
            account: account,
            request_fun: request_fun,
            clock: Keyword.get(opts, :clock, fn -> System.system_time(:second) end),
            name: Keyword.get(opts, :name)}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      result ->
        result
    end
  end

  def payload(row, envelope) do
    body = %{
      "message" => %{
        "token" => row.push_token,
        "data" => %{"s" => envelope["sealed"], "k" => envelope["kid"], "v" => "1"},
        "android" => %{
          "priority" => if(envelope["push_class"] == "alert_high", do: "HIGH", else: "NORMAL"),
          "ttl" => "#{envelope["ttl_s"]}s",
          "collapse_key" => if(envelope["push_class"] == "alert_high", do: "a", else: "b")
        }
      }
    }

    if payload_bytes(body) <= @max_payload_bytes,
      do: {:ok, body},
      else: {:error, :payload_too_large}
  end

  def ready?(auth), do: is_pid(auth) and Process.alive?(auth)

  @impl true
  def deliver(row, envelope) do
    case AiurPushRelay.Provider.Router.provider() do
      {__MODULE__, account, auth, request_fun} ->
        deliver_with(row, envelope, account, auth, request_fun)

      _ ->
        {:error, :provider_unavailable}
    end
  end

  def payload_size(row, envelope) do
    case payload(row, envelope) do
      {:ok, body} -> {:ok, byte_size(Jason.encode!(body))}
      error -> error
    end
  end

  defp payload_bytes(body), do: byte_size(Jason.encode!(body))

  def deliver_with(row, envelope, account, auth, request_fun) do
    with {:ok, body} <- payload(row, envelope),
         {:ok, token} <- AiurPushRelay.Provider.Fcm.Auth.token(auth),
         response <-
           request_fun.(
             url: send_url(account["project_id"]),
             json: body,
             headers: [{"authorization", "Bearer " <> token}],
             retry: false,
             receive_timeout: 15_000
           ) do
      map_response(response)
    else
      {:error, :payload_too_large} = error -> error
      _ -> {:retry, 60_000}
    end
  rescue
    _ -> {:retry, 60_000}
  end

  def send_url(project_id),
    do:
      "https://fcm.googleapis.com/v1/projects/#{URI.encode(project_id, &URI.char_unreserved?/1)}/messages:send"

  def map_response({:ok, %{status: status}}) when status in 200..299, do: :ok

  def map_response({:ok, %{status: 404, body: body}}) do
    if error_code(body) == "UNREGISTERED", do: {:gone, "UNREGISTERED"}, else: {:retry, 60_000}
  end

  def map_response({:ok, %{status: 429, body: body} = response}) do
    if error_code(body) == "QUOTA_EXCEEDED" do
      delay = retry_after(response) || 60
      {:retry, delay * 1000}
    else
      {:retry, 60_000}
    end
  end

  def map_response({:ok, %{status: status}}) when status >= 500, do: {:retry, 60_000}

  def map_response({:ok, %{status: 400, body: body}}) when is_map(body),
    do:
      if(error_code(body) == "INVALID_ARGUMENT",
        do: {:error, {:invalid_argument, "INVALID_ARGUMENT"}},
        else: {:error, :provider_rejected}
      )

  def map_response({:ok, %{status: status}}) when status in 400..499,
    do: {:error, :provider_rejected}

  def map_response(_), do: {:retry, 60_000}

  defp error_code(%{"error" => %{"details" => details}}) when is_list(details) do
    Enum.find_value(details, fn detail ->
      case detail do
        %{"errorCode" => code} when is_binary(code) -> code
        _ -> nil
      end
    end)
  end

  defp error_code(%{"error" => %{"status" => code}}) when is_binary(code), do: code

  defp error_code(_), do: nil

  defp retry_after(response) do
    response.headers
    |> Enum.find_value(fn {key, value} -> if String.downcase(key) == "retry-after", do: value end)
    |> case do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> seconds
          _ -> nil
        end

      _ ->
        nil
    end
  end
end

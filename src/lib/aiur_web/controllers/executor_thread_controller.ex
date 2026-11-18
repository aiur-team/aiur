defmodule AiurWeb.ExecutorThreadController do
  @moduledoc "The operator↔Executor thread API for host apps (see `Aiur.Executor.Thread`)."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Executor.{Thread, ThreadGrant}
  alias AiurWeb.{EndpointConfig, ExecutorThreadAuth}
  alias Plug.Conn

  plug(:no_store)

  @default_limit 50
  @maximum_limit 200
  @maximum_text_bytes 32_768
  @maximum_request_id_bytes 128

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, _params), do: json(conn, Thread.info(thread_opts()))

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    with {:ok, after_pos} <- integer(params["after"], 0, 0, nil),
         {:ok, limit} <- integer(params["limit"], @default_limit, 1, @maximum_limit),
         {:ok, page} <- Thread.messages(after_pos, limit, principal(conn)) do
      json(conn, page)
    else
      {:error, :invalid} -> error(conn, 422, "invalid_params", "after must be a position and limit 1-#{@maximum_limit}")
      {:error, _reason} -> error(conn, 503, "thread_unavailable", "The Executor thread could not be read")
    end
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    with {:ok, text} <- text(params["text"]),
         {:ok, request_id} <- request_id(params["client_request_id"]),
         {:ok, message} <- Thread.send(text, request_id, thread_opts()) do
      conn |> put_status(202) |> json(%{message: message})
    else
      {:error, :invalid_text} -> error(conn, 422, "invalid_text", "text must be 1-#{@maximum_text_bytes} bytes")
      {:error, :invalid_request_id} -> error(conn, 422, "invalid_client_request_id", "client_request_id must be 1-#{@maximum_request_id_bytes} bytes")
      {:error, {:message_id_conflict, _id}} -> error(conn, 409, "client_request_id_conflict", "client_request_id was already used for different text")
      {:error, {:executor_unavailable, reason}} -> conn |> put_status(409) |> json(%{error: "executor_unavailable", reason: Atom.to_string(reason)})
      {:error, {:queue_full, _capacity}} -> error(conn, 503, "queue_full", "The Executor message queue is full")
      {:error, _reason} -> error(conn, 503, "send_failed", "The message was not queued; retry with the same client_request_id")
    end
  end

  @spec mint_grant(Conn.t(), map()) :: Conn.t()
  def mint_grant(conn, params) do
    with {:ok, secret} <- ExecutorThreadAuth.signing_secret(conn),
         {:ok, %{token: token, grant: grant}} <- ThreadGrant.mint(params["subject"], secret: secret, expires_in: params["ttl_s"] || 900) do
      conn |> put_status(201) |> json(%{token: token, expires_at: DateTime.to_iso8601(grant.expires_at)})
    else
      :error -> error(conn, 503, "executor_thread_grant_unconfigured", "This instance cannot issue thread grants")
      {:error, :invalid_grant} -> error(conn, 422, "invalid_grant", "subject is required and ttl_s must be 1-86400")
    end
  end

  defp thread_opts, do: EndpointConfig.get(:executor_thread_opts, [])

  defp text(text) when is_binary(text) and byte_size(text) <= @maximum_text_bytes do
    if String.trim(text) != "" and String.valid?(text), do: {:ok, text}, else: {:error, :invalid_text}
  end

  defp text(_text), do: {:error, :invalid_text}

  defp request_id(id) when is_binary(id) and byte_size(id) in 1..@maximum_request_id_bytes, do: {:ok, id}
  defp request_id(_id), do: {:error, :invalid_request_id}

  defp integer(nil, default, _min, _max), do: {:ok, default}

  defp integer(value, _default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= min and (is_nil(max) or n <= max) -> {:ok, n}
      _ -> {:error, :invalid}
    end
  end

  defp integer(_value, _default, _min, _max), do: {:error, :invalid}

  # A host grant sees the same redacted bodies as a paired device.
  defp principal(%{assigns: %{executor_thread_grant: %{subject: subject}}}), do: {:device, "thread-grant:" <> subject}
  defp principal(%{assigns: %{device_id: id}}) when is_binary(id), do: {:device, id}
  defp principal(_conn), do: {:operator, :basic_auth}

  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")

  defp error(conn, status, code, message), do: conn |> put_status(status) |> json(%{error: %{code: code, message: message}})
end

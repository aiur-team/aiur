defmodule Aiur.Claude.Telemetry.Receiver do
  @moduledoc false

  import Plug.Conn

  alias Aiur.Claude.Telemetry

  @max_body_bytes 32_768
  @read_chunk_bytes 8_192
  @read_timeout_ms 1_000

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, opts) do
    registry = Keyword.fetch!(opts, :registry)

    case authenticate(conn, registry) do
      {:ok, request_id} ->
        try do
          ingest(conn, request_id, registry)
        after
          Telemetry.release_request(request_id, registry)
        end

      {:error, reason, :already_counted} ->
        reject(conn, reason)

      {:error, reason} ->
        Telemetry.reject(reason, registry)
        reject(conn, reason)
    end
  end

  defp authenticate(%{method: "POST", request_path: "/v1/logs"} = conn, registry) do
    with :ok <- json_content_type(conn),
         :ok <- bounded_content_length(conn),
         [authorization] <- get_req_header(conn, "authorization") do
      case Telemetry.authorize(authorization, registry) do
        {:ok, request_id} -> {:ok, request_id}
        {:error, reason} -> {:error, reason, :already_counted}
      end
    else
      [] -> {:error, :unauthenticated}
      [_first | _extra] -> {:error, :unauthenticated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authenticate(_conn, _registry), do: {:error, :unsupported_event}

  defp ingest(conn, request_id, registry) do
    with {:ok, body, conn} <- read_limited_body(conn),
         {:ok, payload} <- decode_json(body),
         {:ingested, :ok} <- {:ingested, Telemetry.ingest(request_id, payload, registry)} do
      conn |> put_resp_content_type("application/json") |> send_resp(200, "{}")
    else
      {:ingested, {:error, reason}} ->
        reject(conn, reason)

      {:error, reason, rejected_conn} ->
        Telemetry.reject(reason, registry)
        reject(rejected_conn, reason)

      {:error, reason} ->
        Telemetry.reject(reason, registry)
        reject(conn, reason)
    end
  end

  defp read_limited_body(conn) do
    case read_body(conn, length: @max_body_bytes, read_length: @read_chunk_bytes, read_timeout: @read_timeout_ms) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _chunk, conn} -> {:error, :oversize, conn}
      {:error, :too_large} -> {:error, :oversize, conn}
      {:error, _reason} -> {:error, :malformed, conn}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body, floats: :decimals) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed}
    end
  end

  defp json_content_type(conn) do
    if Enum.any?(get_req_header(conn, "content-type"), &String.starts_with?(&1, "application/json")), do: :ok, else: {:error, :malformed}
  end

  defp bounded_content_length(conn) do
    case get_req_header(conn, "content-length") do
      [] -> :ok
      [value] -> if(valid_content_length?(value), do: :ok, else: {:error, :oversize})
      _ -> {:error, :malformed}
    end
  end

  defp valid_content_length?(value) do
    case Integer.parse(value) do
      {length, ""} -> length >= 0 and length <= @max_body_bytes
      _ -> false
    end
  end

  defp reject(conn, reason) do
    status =
      cond do
        reason in [:unauthenticated, :unknown_capability] -> 401
        reason in [:oversize, :attribute_limit] -> 413
        reason in [:concurrent_limit, :rate_limited] -> 429
        reason in [:replay, :stale_session] -> 409
        true -> 400
      end

    conn |> put_resp_content_type("application/json") |> send_resp(status, "{}")
  end
end

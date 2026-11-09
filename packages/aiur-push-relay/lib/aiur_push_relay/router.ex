defmodule AiurPushRelay.Router do
  @moduledoc "Small JSON HTTP surface without request-content logging."
  @behaviour Plug
  import Plug.Conn
  alias AiurPushRelay.{Envelope, Handles, Send, Store}

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, opts) do
    route(conn, opts)
  catch
    :exit, _ -> respond(conn, {:error, :store_unavailable})
  end

  defp route(%{method: "GET", path_info: ["healthz"]} = conn, opts) do
    case Store.call(opts.store, :health) do
      :ok -> json(conn, 200, %{store: "ok"})
      _ -> json(conn, 503, %{store: "error"})
    end
  end

  defp route(%{method: "POST", path_info: ["v1", "handles"]} = conn, opts) do
    with {:ok, params, conn} <- body(conn),
         {:ok, result} <- Handles.create(opts.store, opts.pins, params) do
      json(conn, 201, result)
    else
      error -> respond(conn, error)
    end
  end

  defp route(%{method: "DELETE", path_info: ["v1", "handles", handle]} = conn, opts) do
    with {:ok, _} <- Handles.authenticate(opts.store, handle, bearer(conn)),
         :ok <- Store.call(opts.store, :delete, [handle]) do
      send_resp(conn, 204, "")
    else
      error -> respond(conn, error)
    end
  end

  defp route(%{method: "POST", path_info: ["v1", "send"]} = conn, opts) do
    with {:ok, params, conn} <- body(conn),
         true <- is_map(params),
         {:ok, row} <- Handles.authenticate(opts.store, params["handle"], bearer(conn)),
         false <- row.gone,
         {:ok, envelope} <- Envelope.validate(params, Map.get(opts.pins, row.app_topic)),
         {:ok, status} <- Send.enqueue(opts.sender, row, envelope) do
      json(conn, status, %{status: "accepted"})
    else
      true -> respond(conn, {:error, :handle_gone})
      false -> respond(conn, {:error, :schema})
      error -> respond(conn, error)
    end
  end

  defp route(conn, _), do: json(conn, 404, %{error: "not_found"})

  defp body(conn) do
    case read_body(conn, length: 8192, read_length: 8193) do
      {:ok, bytes, conn} when byte_size(bytes) <= 8192 -> decode(bytes, conn)
      {:more, _, _} -> {:error, :too_large}
      {:ok, _, _} -> {:error, :too_large}
      {:error, _} -> {:error, :schema}
    end
  end

  defp decode(bytes, conn) do
    case Jason.decode(bytes) do
      {:ok, params} -> {:ok, params, conn}
      _ -> {:error, :schema}
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> secret] -> secret
      _ -> ""
    end
  end

  defp respond(conn, {:error, reason}) do
    status =
      case reason do
        :unauthorized -> 401
        :handle_unknown -> 404
        :handle_gone -> 410
        :too_large -> 413
        reason when reason in [:schema, :fallback_mismatch] -> 422
        _ -> 503
      end

    json(conn, status, %{error: reason})
  end

  defp json(conn, status, value) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(value))
  end
end

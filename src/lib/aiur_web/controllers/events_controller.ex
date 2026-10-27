defmodule AiurWeb.EventsController do
  @moduledoc "Authenticated pull access to the optional external event journal."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Events.{Catalog, Export}

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    if Export.enabled?() do
      with {:ok, limit} <- integer(params, "limit", 100, 1, 500, :invalid_limit),
           {:ok, after_seq} <- integer(params, "after", Export.status().head_seq, 0, :infinity, :invalid_cursor),
           {:ok, patterns} <- patterns(params),
           {:ok, opts} <- epoch(params) do
        render_read(conn, Export.read(after_seq, limit, patterns, opts))
      else
        {:error, code} -> error(conn, 422, code, "invalid event feed query")
      end
    else
      disabled(conn)
    end
  end

  @spec catalog(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def catalog(conn, _params) do
    if Export.enabled?() do
      topics = Enum.map(Catalog.exported(), &Map.take(&1, [:pattern, :class, :payload_version]))
      respond(conn, 200, %{v: 1, topics: topics})
    else
      disabled(conn)
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn |> Plug.Conn.put_resp_header("allow", "GET") |> error(405, :method_not_allowed, "method not allowed")
  end

  defp render_read(conn, {:ok, result}), do: respond(conn, 200, result)

  defp render_read(conn, {:reset, meta}) do
    record = meta |> Map.take([:oldest_seq, :head_seq]) |> Map.put(:type, "reset")
    result = meta |> Map.put(:instance, Export.status().instance) |> Map.put(:records, [record])
    respond(conn, 200, result)
  end

  defp render_read(conn, {:error, :events_unavailable}), do: error(conn, 503, :events_unavailable, "event journal is unavailable")

  defp integer(params, key, default, min, max, code) do
    case Map.fetch(params, key) do
      :error -> {:ok, default}
      {:ok, value} -> parse_integer(value, min, max, code)
    end
  end

  defp parse_integer(value, min, max, code) when is_binary(value) do
    with true <- Regex.match?(~r/\A[0-9]+\z/, value),
         {number, ""} <- Integer.parse(value),
         true <- number >= min and (max == :infinity or number <= max) do
      {:ok, number}
    else
      _ -> {:error, code}
    end
  end

  defp parse_integer(_, _, _, code), do: {:error, code}

  defp epoch(%{"epoch" => epoch}) when is_binary(epoch), do: {:ok, [epoch: epoch]}
  defp epoch(%{"epoch" => _}), do: {:error, :invalid_cursor}
  defp epoch(_), do: {:ok, []}

  defp patterns(params) do
    exported = Enum.map(Catalog.exported(), & &1.pattern)

    case Map.fetch(params, "topics") do
      :error -> {:ok, exported}
      {:ok, value} when is_binary(value) -> validate_patterns(String.split(value, ","), exported)
      _ -> {:error, :topic_not_exported}
    end
  end

  defp validate_patterns(requested, exported) do
    if Enum.all?(requested, fn pattern ->
         valid_pattern?(pattern) and Enum.any?(exported, &narrowing?(String.split(pattern, "."), String.split(&1, ".")))
       end) do
      {:ok, requested}
    else
      {:error, :topic_not_exported}
    end
  end

  defp valid_pattern?(pattern) do
    Enum.all?(String.split(pattern, "."), &(&1 in ["*", "#"] or Regex.match?(~r/\A[^\s.*#]+\z/u, &1)))
  end

  # Deliberately conservative: keep segment positions and replace wildcards only with literals.
  defp narrowing?([], []), do: true
  defp narrowing?([same | requested], [same | exported]), do: narrowing?(requested, exported)

  defp narrowing?([literal | requested], [wildcard | exported]) when wildcard in ["*", "#"] and literal not in ["*", "#"],
    do: narrowing?(requested, exported)

  defp narrowing?(_, _), do: false

  defp disabled(conn), do: error(conn, 404, :feature_disabled, "event export is disabled (events.export.enabled: false)")
  defp error(conn, status, code, message), do: respond(conn, status, %{error: %{code: code, message: message}})
  defp respond(conn, status, body), do: conn |> Plug.Conn.put_resp_header("cache-control", "no-store") |> put_status(status) |> json(body)
end

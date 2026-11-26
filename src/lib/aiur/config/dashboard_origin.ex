defmodule Aiur.Config.DashboardOrigin do
  @moduledoc "Normal form for `server.dashboard_origins` entries."

  @loopback ["localhost", "127.0.0.1", "[::1]", "::1"]

  @doc "Normalise to `scheme://host[:port]`; `http` is accepted for loopback hosts only."
  @spec normalize_origin(term()) :: {:ok, String.t()} | :error
  def normalize_origin(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and path in [nil, "", "/"] ->
        render(scheme, String.downcase(host), port)

      _ ->
        :error
    end
  end

  def normalize_origin(_), do: :error

  @doc "Normalised origin, or the entry unchanged when it is not an origin (validation reports it)."
  @spec normalize_or_keep(String.t()) :: String.t()
  def normalize_or_keep(value) do
    case normalize_origin(value) do
      {:ok, origin} -> origin
      :error -> value
    end
  end

  defp render("http", host, _port) when host not in @loopback, do: :error
  defp render("https", host, port), do: {:ok, "https://#{host}" <> port_suffix(port, 443)}
  defp render("http", host, port), do: {:ok, "http://#{host}" <> port_suffix(port, 80)}

  defp port_suffix(port, default) when port in [nil, default], do: ""
  defp port_suffix(port, _default), do: ":#{port}"
end

defmodule AiurWeb.HostAllowlist do
  @moduledoc "Reject requests whose Host header is outside the configured dashboard hosts."

  @behaviour Plug

  import Plug.Conn
  require Logger

  @loopback_hosts ["localhost", "127.0.0.1", "[::1]", "::1"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    config = AiurWeb.EndpointConfig
    allowed_hosts = config.get(:allowed_hosts, [])
    allow_tailnet_hosts? = config.get(:allow_tailnet_hosts, false)
    observed_host = host_name(conn.host)
    log_first_observed_request(conn)

    if webhook_request?(conn) or allowed_host?(observed_host, allowed_hosts, allow_tailnet_hosts?) do
      conn
    else
      conn
      |> send_resp(:forbidden, "Forbidden")
      |> halt()
    end
  end

  @doc false
  @spec allowed_hosts(String.t() | nil, [String.t()] | nil, boolean()) :: [String.t()]
  def allowed_hosts(public_url, configured_hosts \\ nil, allow_tailnet_hosts? \\ false) do
    hosts = [public_url_host(public_url) | @loopback_hosts] ++ List.wrap(configured_hosts)
    hosts = if allow_tailnet_hosts?, do: ["*.ts.net" | hosts], else: hosts
    hosts |> Enum.reject(&is_nil/1) |> Enum.map(&normalize_host/1) |> Enum.uniq()
  end

  @doc false
  @spec origins(String.t() | nil) :: [String.t()]
  def origins(public_url) do
    public_origin =
      public_url
      |> url_parts()
      |> then(fn
        nil -> nil
        uri -> "#{uri.scheme}://#{uri.host}" <> port_suffix(uri)
      end)

    [public_origin, "//localhost", "//127.0.0.1", "//[::1]"]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc false
  @spec check_origin(URI.t(), [String.t()], boolean()) :: boolean()
  def check_origin(%URI{scheme: "https", host: host}, _origins, true)
      when is_binary(host) and host != "ts.net" do
    String.ends_with?(String.downcase(host), ".ts.net")
  end

  def check_origin(%URI{host: host, scheme: scheme, port: port}, origins, _allow_tailnet?) do
    Enum.any?(origins, fn origin ->
      allowed = URI.parse(origin)

      (is_nil(allowed.scheme) or allowed.scheme == scheme) and
        (is_nil(allowed.port) or allowed.port == port) and
        normalize_host(allowed.host) == normalize_host(host)
    end)
  end

  defp public_url_host(nil), do: nil
  defp public_url_host(url), do: url |> url_parts() |> then(&if(&1, do: &1.host))

  defp url_parts(url) when is_binary(url) do
    uri = URI.parse(url)
    if uri.scheme in ["http", "https"] and is_binary(uri.host), do: uri, else: nil
  end

  defp url_parts(_), do: nil

  defp port_suffix(%URI{port: nil}), do: ""
  defp port_suffix(%URI{scheme: "http", port: 80}), do: ""
  defp port_suffix(%URI{scheme: "https", port: 443}), do: ""
  defp port_suffix(%URI{port: port}), do: ":#{port}"

  defp host_name(nil), do: nil
  defp host_name(value), do: value |> String.trim_leading("[") |> String.trim_trailing("]") |> String.trim_trailing(".")

  defp normalize_host(host) when is_binary(host), do: String.downcase(String.trim_trailing(host, "."))
  defp normalize_host(host), do: host

  defp allowed_host?(host, allowed_hosts, allow_tailnet_hosts?) when is_binary(host) do
    normalized = normalize_host(host)

    Enum.any?(allowed_hosts, fn allowed ->
      allowed = normalize_host(allowed)
      normalized == allowed or (allow_tailnet_hosts? and allowed == "*.ts.net" and String.ends_with?(normalized, ".ts.net"))
    end)
  end

  defp allowed_host?(_host, _allowed_hosts, _allow_tailnet_hosts?), do: false

  defp webhook_request?(%Plug.Conn{method: "POST"} = conn), do: AiurWeb.GithubWebhook.receiver_request?(conn)
  defp webhook_request?(_conn), do: false

  defp log_first_observed_request(conn) do
    key = {__MODULE__, AiurWeb.Endpoint}
    host = host_name(conn.host)
    origin = Plug.Conn.get_req_header(conn, "origin") |> List.first()

    unless :persistent_term.get(key, nil) do
      :global.trans({key, self()}, fn -> log_first_observed_request_once(key, host, origin) end)
    end
  end

  defp log_first_observed_request_once(key, host, origin) do
    if is_nil(:persistent_term.get(key, nil)) do
      Logger.info("Aiur dashboard first observed request Host=#{inspect(host)} Origin=#{inspect(origin)}")
      :persistent_term.put(key, true)
    end
  end
end

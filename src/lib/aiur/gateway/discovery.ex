defmodule Aiur.Gateway.Discovery do
  @moduledoc """
  `aiur gateway discover`: probe registry entries and tag-filtered tailnet peers with the anonymous hello.

  Read-only: it never writes the registry, a token file or a grant, and sends no credential to a peer.
  An unanswered tailnet peer is omitted; an unanswered registry entry is `unreachable`, never `offline`.
  """

  alias Aiur.Gateway.{Hello, Registry}

  @tag "tag:gateway"
  @hello_path "/api/v1/gateway/hello"
  @max_body 4096
  @keys Enum.map(Hello.keys(), &Atom.to_string/1)

  @type row :: %{name: String.t(), url: String.t(), status: String.t(), gateway_id: String.t() | nil}

  @spec discover(keyword()) :: %{tailscale_found: boolean(), rows: [row()]}
  def discover(opts \\ []) do
    get = Keyword.get(opts, :http_get, &http_get/1)
    registry = registry_targets()

    {tailscale_found, peers} = tailnet_targets(opts)
    known = registry |> Enum.map(& &1.url) |> MapSet.new()
    peers = Enum.reject(peers, &(&1.url in known))

    rows =
      (registry ++ peers)
      |> Task.async_stream(&probe(&1, get), max_concurrency: 8, timeout: 10_000, on_timeout: :kill_task, zip_input_on_exit: true)
      |> Enum.map(fn
        {:ok, row} -> row
        {:exit, {target, _reason}} -> row(target, "unreachable", nil)
      end)
      |> Enum.reject(&(&1.status == :omit))

    %{tailscale_found: tailscale_found, rows: rows}
  end

  defp registry_targets do
    case Registry.get() do
      {:ok, view} ->
        for {name, instance} <- view.instances, is_map(instance), is_binary(instance["url"]) do
          %{name: to_string(name), url: hello_url(instance["url"]), pin: instance["gateway_id"], registered: true}
        end

      {:error, _reason} ->
        []
    end
  end

  @doc false
  @spec hello_url(String.t()) :: String.t()
  def hello_url(url), do: String.trim_trailing(url, "/") <> @hello_path

  defp tailnet_targets(opts) do
    case Aiur.TailscaleFunnel.command(["status", "--json"], Keyword.take(opts, [:tailscale_executable, :tailscale_runner])) do
      {:ok, json} -> {true, peers(json, Keyword.get(opts, :port) || local_port())}
      {:error, :tailscale_executable_not_found} -> {false, []}
      # Unparseable or failing tailscale output is "no tailnet data", not a crash.
      {:error, _reason} -> {true, []}
    end
  end

  defp peers(json, port) do
    case Jason.decode(json) do
      {:ok, %{"Peer" => peers}} when is_map(peers) ->
        for {_key, peer} <- peers,
            peer["Online"] == true,
            @tag in (peer["Tags"] || []),
            dns = peer["DNSName"],
            is_binary(dns),
            port do
          host = String.trim_trailing(dns, ".")
          %{name: host, url: "http://#{host}:#{port}#{@hello_path}", pin: nil, registered: false}
        end

      _ ->
        []
    end
  end

  defp local_port do
    case AiurWeb.EndpointConfig.get(:http, nil) do
      http when is_list(http) -> positive(http[:port])
      _ -> nil
    end
  end

  defp positive(port) when is_integer(port) and port > 0, do: port
  defp positive(_port), do: nil

  defp probe(target, get) do
    case get.(target.url) do
      {:ok, %{} = body} -> classify(target, body)
      {:error, :unrecognised} -> row(target, "answered, unrecognised", nil)
      {:error, _reason} -> if target.registered, do: row(target, "unreachable", nil), else: row(target, :omit, nil)
    end
  end

  defp classify(target, body) do
    id = body["gateway_id"]

    cond do
      Enum.sort(Map.keys(body)) != Enum.sort(@keys) -> row(target, "answered, unrecognised", nil)
      target.pin && id != target.pin -> row(target, "identity mismatch", nil)
      target.registered -> row(target, "enrolled", id)
      registered_id?(id) -> row(target, "enrolled", id)
      true -> row(target, "discovered (not enrolled)", id)
    end
  end

  defp registered_id?(nil), do: false

  defp registered_id?(id) do
    case Registry.get() do
      {:ok, %{peers: peers}} -> Enum.any?(peers, fn {_name, peer} -> peer.gateway_id == id end)
      {:error, _reason} -> false
    end
  end

  defp row(target, status, id), do: %{name: target.name, url: target.url, status: status, gateway_id: id}

  # ponytail: the 4 KiB cap is checked after the read; switch to a streaming `into:` if a hostile peer matters.
  @doc false
  @spec http_get(String.t()) :: {:ok, map()} | {:error, term()}
  def http_get(url) do
    case Req.get(url, receive_timeout: 2000, connect_options: [timeout: 2000], redirect: false, retry: false, decode_body: false, headers: []) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= @max_body ->
        case Jason.decode(body) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> {:error, :unrecognised}
        end

      {:ok, %{status: 200}} ->
        {:error, :unrecognised}

      {:ok, _other} ->
        {:error, :unrecognised}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

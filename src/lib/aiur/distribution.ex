# Keep runtime inspection and pure address parsing together: startup uses the
# same fail-closed interpretation that the injected socket-table tests verify.
defmodule Aiur.Distribution do
  @moduledoc """
  Runtime checks and monitoring for Aiur's local-only Erlang distribution.
  """

  require Logger

  @type result :: :ok | {:error, atom()}

  @spec start!() :: result()
  def start! do
    start!(&:net_kernel.monitor_nodes/2)
  end

  @doc false
  @spec start!((boolean(), keyword() -> :ok)) :: result()
  def start!(monitor_fn) when is_function(monitor_fn, 2) do
    case check_runtime() do
      :ok ->
        do_monitor_hidden_nodes(monitor_fn)

      {:error, reason} = error ->
        Logger.error(unsafe_reason(reason))
        error
    end
  end

  @doc false
  @spec check(keyword()) ::
          :ok | {:error, :not_distributed | :epmd_not_local | :epmd_unverifiable | :dist_not_local | :baked_cookie}
  def check(opts) do
    if Keyword.fetch!(opts, :alive?) do
      cond do
        not loopback_all?(Keyword.fetch!(opts, :epmd_address)) -> {:error, :epmd_not_local}
        not loopback_all?(Keyword.fetch!(opts, :dist_address)) -> {:error, :dist_not_local}
        baked_cookie?(opts) -> {:error, :baked_cookie}
        true -> :ok
      end
    else
      :ok
    end
  end

  @spec node_name() :: atom() | nil
  def node_name, do: node_name(&Node.self/0)

  @doc false
  @spec node_name((-> atom())) :: atom() | nil
  def node_name(node_self_fn) when is_function(node_self_fn, 0) do
    case node_self_fn.() do
      :nonode@nohost -> nil
      name -> name
    end
  end

  @spec epmd_address() :: String.t()
  def epmd_address, do: System.get_env("ERL_EPMD_ADDRESS", "")

  @spec hidden_pane_nodes() :: [node()]
  def hidden_pane_nodes, do: Node.list(:hidden)

  defp check_runtime do
    if Node.alive?() do
      with {:ok, dist_addresses} <- distribution_addresses(),
           {:ok, epmd_address} <- epmd_address_bound() do
        check(
          alive?: true,
          dist_address: dist_addresses,
          epmd_address: epmd_address,
          running_cookie: :erlang.get_cookie() |> Atom.to_string() |> String.to_charlist(),
          release_cookie: release_cookie()
        )
      end
    else
      :ok
    end
  end

  defp distribution_addresses do
    # net_kernel's #state.listen list contains #listen tuples; the socket is field 2.
    with {:ok, state} <- safe_state(),
         {:ok, addresses} <- listen_addresses(state),
         true <- Enum.all?(addresses, &(not is_nil(&1))) do
      {:ok, addresses}
    else
      _ -> {:error, :dist_not_local}
    end
  end

  defp listen_addresses(state) when is_tuple(state) do
    with [_tag | fields] when length(fields) >= 9 <- Tuple.to_list(state),
         listeners when is_list(listeners) and listeners != [] <- Enum.at(fields, 8) do
      {:ok, Enum.map(listeners, &listener_address/1)}
    else
      _ -> {:error, :dist_not_local}
    end
  end

  defp listen_addresses(_state), do: {:error, :dist_not_local}

  defp listener_address(listener) when is_tuple(listener) and tuple_size(listener) >= 2 do
    case :inet.sockname(elem(listener, 1)) do
      {:ok, {address, _port}} -> address
      _ -> nil
    end
  end

  defp listener_address(_listener), do: nil

  defp safe_state do
    {:ok, :sys.get_state(:net_kernel)}
  catch
    _, _ -> {:error, :dist_not_local}
  end

  defp epmd_address_bound do
    case proc_epmd_listeners() do
      {:ok, []} -> {:error, :epmd_unverifiable}
      {:ok, addresses} -> {:ok, addresses}
      :unavailable -> lsof_epmd_listeners()
    end
  end

  @doc false
  @spec parse_epmd_output(String.t()) :: {:ok, [tuple()]} | {:error, :epmd_unverifiable}
  def parse_epmd_output(output) when is_binary(output) do
    port = epmd_port()

    matches =
      Regex.scan(~r/(\*|(?:\d{1,3}\.){3}\d{1,3}|\[[0-9a-fA-F:]+\]):(\d+)/, output, capture: :all_but_first)
      |> Enum.filter(fn [_address, listener_port] -> listener_port == port end)

    parse_epmd_matches(matches)
  end

  @doc false
  @spec parse_proc_listeners(String.t(), String.t(), String.t() | integer()) ::
          {:ok, [tuple()]} | {:error, :epmd_unverifiable}
  def parse_proc_listeners(tcp4, tcp6, port) when is_binary(tcp4) and is_binary(tcp6) do
    with {:ok, port} <- parse_epmd_port(port) do
      addresses = parse_proc_table(tcp4, :inet, port) ++ parse_proc_table(tcp6, :inet6, port)

      case addresses do
        [] -> {:error, :epmd_unverifiable}
        _ -> {:ok, addresses}
      end
    end
  end

  defp parse_epmd_matches([]), do: {:error, :epmd_unverifiable}

  defp parse_epmd_matches(matches) do
    addresses = Enum.map(matches, &parse_epmd_address/1)
    if Enum.all?(addresses, &(not is_nil(&1))), do: {:ok, addresses}, else: {:error, :epmd_unverifiable}
  end

  defp parse_epmd_address(["*", _port]), do: {0, 0, 0, 0}

  defp parse_epmd_address(["[" <> address, _port]) do
    address
    |> String.trim_trailing("]")
    |> parse_ip()
  end

  defp parse_epmd_address([address, _port]), do: parse_ip(address)

  defp parse_ip(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp proc_epmd_listeners do
    if :os.type() == {:unix, :linux} do
      with {:ok, tcp4} <- File.read("/proc/net/tcp"),
           {:ok, tcp6} <- File.read("/proc/net/tcp6"),
           {:ok, port} <- parse_epmd_port(epmd_port()) do
        {:ok, parse_proc_table(tcp4, :inet, port) ++ parse_proc_table(tcp6, :inet6, port)}
      else
        _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  defp parse_proc_table(contents, family, port) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [_slot, local_address, _remote_address, "0A" | _rest] ->
          parse_proc_socket(local_address, family, port)

        _ ->
          []
      end
    end)
  end

  defp parse_proc_socket(local_address, family, port) do
    case String.split(local_address, ":", parts: 2) do
      [address_hex, port_hex] ->
        parse_proc_socket_address(address_hex, port_hex, family, port)

      _ ->
        []
    end
  end

  defp parse_proc_socket_address(address_hex, port_hex, family, port) do
    with {parsed_port, ""} <- Integer.parse(port_hex, 16),
         true <- parsed_port == port,
         address when not is_nil(address) <- decode_proc_address(address_hex, family) do
      [address]
    else
      _ -> []
    end
  end

  defp decode_proc_address(address_hex, :inet) when byte_size(address_hex) == 8 do
    address_hex
    |> hex_bytes()
    |> Enum.reverse()
    |> List.to_tuple()
  end

  defp decode_proc_address(address_hex, :inet6) when byte_size(address_hex) == 32 do
    address_hex
    |> String.graphemes()
    |> Enum.chunk_every(8)
    |> Enum.flat_map(fn word -> word |> Enum.chunk_every(2) |> Enum.reverse() |> Enum.map(&Enum.join/1) end)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [high, low] -> String.to_integer(high <> low, 16) end)
    |> List.to_tuple()
  end

  defp decode_proc_address(_address_hex, _family), do: nil

  defp hex_bytes(address_hex) do
    address_hex
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map(fn byte -> byte |> Enum.join() |> String.to_integer(16) end)
  end

  defp lsof_epmd_listeners do
    with lsof when is_binary(lsof) <- System.find_executable("lsof"),
         port when is_binary(port) <- epmd_port() do
      case System.cmd(lsof, ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN"], stderr_to_stdout: true) do
        {output, 0} -> parse_epmd_output(output)
        _ -> {:error, :epmd_unverifiable}
      end
    else
      _ -> {:error, :epmd_unverifiable}
    end
  rescue
    _ -> {:error, :epmd_unverifiable}
  end

  defp epmd_port, do: System.get_env("ERL_EPMD_PORT") || "4369"

  defp parse_epmd_port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}

  defp parse_epmd_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {parsed, ""} when parsed in 1..65_535 -> {:ok, parsed}
      _ -> {:error, :epmd_unverifiable}
    end
  end

  defp parse_epmd_port(_port), do: {:error, :epmd_unverifiable}

  defp release_cookie do
    case release_root() do
      nil ->
        nil

      root ->
        case File.read(Path.join(root, "releases/COOKIE")) do
          {:ok, cookie} -> cookie |> String.trim() |> String.to_charlist()
          _ -> nil
        end
    end
  end

  defp release_root do
    case :code.lib_dir(:aiur) do
      path when is_list(path) -> path |> List.to_string() |> Path.dirname() |> Path.dirname()
      _ -> nil
    end
  end

  defp baked_cookie?(opts) do
    case {Keyword.get(opts, :running_cookie), Keyword.get(opts, :release_cookie)} do
      {cookie, cookie} when not is_nil(cookie) -> true
      _ -> false
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
  defp loopback_all?(addresses) when is_list(addresses), do: addresses != [] and Enum.all?(addresses, &loopback?/1)
  defp loopback_all?(address), do: loopback?(address)

  defp unsafe_reason(:epmd_not_local),
    do: "epmd listener is not loopback; verify ERL_EPMD_ADDRESS=127.0.0.1"

  defp unsafe_reason(:epmd_unverifiable),
    do: "epmd listener could not be verified; Linux needs readable /proc/net/tcp and /proc/net/tcp6, and other systems need lsof"

  defp unsafe_reason(:dist_not_local),
    do: "Erlang distribution listener is not loopback; verify inet_dist_use_interface"

  defp unsafe_reason(:baked_cookie),
    do: "running cookie matches releases/COOKIE; set a unique RELEASE_COOKIE"

  defp do_monitor_hidden_nodes(monitor_fn) do
    monitor_fn.(true, node_type: :hidden)
    :ok
  rescue
    error ->
      Logger.warning("Distribution monitor setup failed: #{Exception.message(error)}")
      {:error, :not_distributed}
  end
end

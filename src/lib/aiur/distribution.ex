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
  @spec check(keyword()) :: :ok | {:error, :not_distributed | :epmd_not_local | :dist_not_local | :baked_cookie}
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
  def node_name(node_self_fn) do
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
    case System.cmd("sh", ["-c", "pid=$(pgrep -x epmd | head -n 1); [ -n \"$pid\" ] && lsof -nP -a -p \"$pid\" -iTCP -sTCP:LISTEN 2>/dev/null"], stderr_to_stdout: true) do
      {output, 0} ->
        parse_epmd_output(output)

      _ ->
        {:error, :epmd_not_local}
    end
  end

  @doc false
  @spec parse_epmd_output(String.t()) :: {:ok, [tuple()]} | {:error, :epmd_not_local}
  def parse_epmd_output(output) when is_binary(output) do
    matches = Regex.scan(~r/(\*|(?:\d{1,3}\.){3}\d{1,3}|\[[0-9a-fA-F:]+\]):(\d+)/, output, capture: :all_but_first)
    epmd_addresses(matches)
  end

  defp epmd_addresses([]), do: {:error, :epmd_not_local}

  defp epmd_addresses(matches) do
    addresses = Enum.map(matches, &parse_epmd_address/1)
    if Enum.all?(addresses, &(not is_nil(&1))), do: {:ok, addresses}, else: {:error, :epmd_not_local}
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

  defp unsafe_reason(:dist_not_local),
    do: "Erlang distribution listener is not loopback; verify inet_dist_use_interface"

  defp unsafe_reason(:baked_cookie),
    do: "running cookie matches releases/COOKIE; set a unique RELEASE_COOKIE"

  defp unsafe_reason(reason), do: "distribution check failed: #{inspect(reason)}"

  defp do_monitor_hidden_nodes(monitor_fn) do
    monitor_fn.(true, node_type: :hidden)
    :ok
  rescue
    error ->
      Logger.warning("Distribution monitor setup failed: #{Exception.message(error)}")
      {:error, :not_distributed}
  end
end

defmodule Aiur.Opencode.BridgePort do
  @moduledoc false

  require Logger

  @scan_limit 100

  @type source :: Aiur.Opencode.Config.bridge_port_source()

  @spec resolve(String.t(), {source(), non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def resolve(_host, {_source, 0}), do: {:ok, 0}

  def resolve(host, {:default, port}) do
    ip = parse_ip(host)

    if available?(ip, port) do
      {:ok, port}
    else
      case find_available(ip, port + 1) do
        {:ok, selected} ->
          Logger.warning("opencode_bridge default_port_occupied port=#{port} selected_port=#{selected} owner=#{inspect(owner(port))}")

          {:ok, selected}

        :error ->
          {:error, occupied_message(port, :default)}
      end
    end
  end

  def resolve(host, {source, port}) do
    ip = parse_ip(host)

    if available?(ip, port) do
      {:ok, port}
    else
      {:error, occupied_message(port, source)}
    end
  end

  defp find_available(_ip, port) when port > 65_535, do: :error

  defp find_available(ip, start_port) do
    start_port..min(65_535, start_port + @scan_limit - 1)
    |> Enum.find(&available?(ip, &1))
    |> case do
      nil -> :error
      port -> {:ok, port}
    end
  end

  defp available?(ip, port) do
    case :gen_tcp.listen(port, [:binary, {:active, false}, {:ip, ip}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp occupied_message(port, source) do
    owner_text =
      case owner(port) do
        nil -> "another process"
        text -> text
      end

    next_port = min(port + 1, 65_535)

    "opencode bridge port #{port} is already in use by #{owner_text}; " <>
      "stop that process or launch with AIUR_OPENCODE_BRIDGE_PORT=#{next_port}" <>
      explicit_source_note(source)
  end

  defp explicit_source_note(:env), do: " (currently pinned by AIUR_OPENCODE_BRIDGE_PORT)"
  defp explicit_source_note(:workflow), do: " (currently pinned by workflow opencode.bridge_port)"
  defp explicit_source_note(:app_override), do: " (currently pinned by application env)"
  defp explicit_source_note(:default), do: ""

  defp owner(port) do
    case System.find_executable("lsof") do
      nil ->
        nil

      _ ->
        case System.cmd("lsof", ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN"], stderr_to_stdout: true) do
          {out, 0} -> parse_lsof(out)
          _ -> nil
        end
    end
  end

  defp parse_lsof(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> List.first()
    |> case do
      nil ->
        nil

      line ->
        case String.split(line, ~r/\s+/, trim: true) do
          [command, pid | _] -> "#{command} pid #{pid}"
          _ -> nil
        end
    end
  end

  defp parse_ip(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> address
      {:error, _} -> {127, 0, 0, 1}
    end
  end
end

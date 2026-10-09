defmodule Aiur.AppServer.RelayPort do
  @moduledoc "Detached provider controller emitting the same messages as an Erlang Port."
  use GenServer
  require Logger

  alias Aiur.{AgentEnvironment, Boot, Config, ProcessReaper, ProcessTree}
  alias Aiur.Config.Paths

  @spec start(Path.t(), String.t(), list(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(workspace, command, env, opts \\ []) do
    GenServer.start(__MODULE__, {:spawn, self(), workspace, command, env, opts})
  end

  @spec call(pid(), term()) :: term()
  def call(pid, request), do: GenServer.call(pid, request, 15_000)

  @spec attach(Path.t(), pos_integer(), non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def attach(directory, generation, offset) do
    GenServer.start(__MODULE__, {:attach, self(), directory, generation, offset})
  end

  @spec generation(Path.t()) :: pos_integer()
  def generation(root) do
    key = {__MODULE__, root, Boot.run_id()}

    :global.trans({key, self()}, fn ->
      case :persistent_term.get(key, nil) do
        nil ->
          mint_generation(root, key)

        value ->
          value
      end
    end)
  end

  defp mint_generation(root, key) do
    File.mkdir_p!(root)
    path = Path.join(root, "generation")
    previous = if File.exists?(path), do: path |> File.read!() |> String.trim() |> String.to_integer(), else: 0
    value = previous + 1
    File.write!(path <> ".next", Integer.to_string(value), [:sync])
    File.rename!(path <> ".next", path)
    :persistent_term.put(key, value)
    value
  end

  @impl true
  def init({:spawn, owner, workspace, command, env, opts}) do
    with {:ok, root} <- Paths.runtime_state_dir(),
         {:ok, directory} <- launch(root, workspace, command, env, opts) do
      try do
        case connect(owner, directory, generation(Path.join(root, "agent-relays")), 0) do
          {:stop, _reason} = error ->
            cleanup_failed_launch(directory)
            error

          result ->
            result
        end
      rescue
        error ->
          cleanup_failed_launch(directory)
          {:stop, {:relay_start_failed, Exception.message(error)}}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def init({:attach, owner, directory, generation, offset}), do: connect(owner, directory, generation, offset)

  defp launch(root, workspace, command, env, opts) do
    nonce = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    id = "#{Paths.repo_name()}.#{Paths.sanitize(Path.basename(workspace))}.#{nonce}"
    directory = Path.join([root, "agent-relays", id])
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    spec_path = Path.join(directory, "spawn.json")

    spec = %{
      argv: [System.find_executable("bash"), "-c", AgentEnvironment.scrub_shell_command(command, trusted_bash_env: true)],
      cwd: workspace,
      env: launch_env(env),
      backend: Keyword.get(opts, :backend, "app_server"),
      relay_id: id,
      spawn_nonce: nonce,
      orphan_timeout_seconds: Config.settings!().agent.relay_orphan_timeout_seconds
    }

    File.write!(spec_path, Jason.encode!(spec))
    File.chmod!(spec_path, 0o600)
    script = Keyword.get(opts, :relay_script, Application.app_dir(:aiur, "priv/agent_relay.py"))

    case System.cmd("python3", [script, "--directory", directory, "--spec", spec_path], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, directory}
      {output, status} -> {:error, {:relay_launch_failed, status, output}}
    end
  end

  defp launch_env(env) do
    Enum.reduce(env, System.get_env(), fn
      {key, false}, acc -> Map.delete(acc, to_string(key))
      {key, value}, acc -> Map.put(acc, to_string(key), to_string(value))
    end)
  end

  defp connect(owner, directory, generation, offset) do
    socket_path = Path.join(directory, "ctl.sock")

    with {:ok, socket} <- connect_socket(socket_path, 100),
         :ok <- send_json(socket, %{op: "hello"}),
         {:ok, hello} <- receive_json(socket),
         :ok <- validate_hello(hello),
         :ok <- send_json(socket, %{op: "attach", generation: generation, from_offset: offset}),
         {:ok, %{"op" => "attached"}} <- receive_json(socket) do
      metadata =
        Map.new(~w(relay_pid provider_pid pgid relay_id spawn_nonce journal_end acked_offset)a, fn key ->
          {key, Map.fetch!(hello, Atom.to_string(key))}
        end)
        |> Map.merge(%{directory: directory, generation: generation})

      ProcessReaper.register(:agent, {:os_pid, metadata.relay_pid}, comm: "agent_relay.py")
      :ok = :inet.setopts(socket, packet: :raw, active: :once)
      {:ok, %{owner: owner, monitor: Process.monitor(owner), socket: socket, metadata: metadata, exited: false, closing: nil, pending: ""}}
    else
      error ->
        {:stop, {:relay_connect_failed, error}}
    end
  end

  defp validate_hello(%{
         "op" => "hello",
         "protocol" => 1,
         "lossy" => false,
         "relay_pid" => relay,
         "provider_pid" => provider,
         "pgid" => pgid,
         "relay_id" => id,
         "spawn_nonce" => nonce,
         "journal_end" => finish,
         "acked_offset" => ack
       }),
       do: validate_identity([relay, provider, pgid], id, nonce, finish, ack)

  defp validate_hello(hello), do: {:error, {:relay_incompatible, hello}}

  defp validate_identity(pids, id, nonce, finish, ack) do
    valid_pids = Enum.all?(pids, &(is_integer(&1) and &1 > 0))
    valid_offsets = Enum.all?([finish, ack], &(is_integer(&1) and &1 >= 0))

    if valid_pids and valid_offsets and ack <= finish and is_binary(id) and is_binary(nonce),
      do: :ok,
      else: {:error, :invalid_relay_identity}
  end

  defp connect_socket(_path, 0), do: {:error, :relay_socket_missing}

  defp connect_socket(path, attempts) do
    case :gen_tcp.connect({:local, String.to_charlist(socket_address(path))}, 0, [:binary, packet: :line, packet_size: 134_217_728, active: false], 1_000) do
      {:error, reason} when reason in [:enoent, :enametoolong] ->
        Process.sleep(20)
        connect_socket(path, attempts - 1)

      result ->
        result
    end
  end

  # Linux resolves this short alias to the same owner-only socket, even when
  # the configured state root exceeds Unix sockaddr's path limit.
  defp socket_address(path) when byte_size(path) > 100 do
    with {:ok, body} <- File.read(Path.join(Path.dirname(path), "relay.json")),
         {:ok, %{"relay_pid" => pid}} <- Jason.decode(body),
         true <- File.dir?("/proc/#{pid}/cwd") do
      "/proc/#{pid}/cwd/ctl.sock"
    else
      _ -> path
    end
  end

  defp socket_address(path), do: path

  defp receive_json(socket) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000), do: Jason.decode(line)
  end

  defp send_json(socket, frame), do: :gen_tcp.send(socket, Jason.encode!(frame) <> "\n")

  defp cleanup_failed_launch(directory) do
    with {:ok, body} <- File.read(Path.join(directory, "relay.json")),
         {:ok, %{"relay_pid" => pid}} <- Jason.decode(body),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <- String.contains?(cmdline, "agent_relay.py") do
      ProcessTree.graceful_kill_tree(pid)
    else
      _ -> :ok
    end
  end

  @impl true
  def handle_call(:metadata, _from, state), do: {:reply, state.metadata, state}

  def handle_call({:command, line}, _from, state) do
    case send_json(state.socket, %{op: "stdin", line: line}) do
      :ok -> {:reply, true, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_call(:detach, _from, state) do
    :ok = send_json(state.socket, %{op: "detach"})
    :gen_tcp.close(state.socket)
    {:stop, :normal, state.metadata, state}
  end

  def handle_call(:close, from, state) do
    case send_json(state.socket, %{op: "stop", grace_ms: 10_000}) do
      :ok ->
        Process.send_after(self(), :close_timeout, 12_000)
        {:noreply, %{state | closing: from}}

      {:error, _reason} ->
        {:stop, :normal, true, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    state = consume(state.pending <> line, %{state | pending: ""})
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    unless state.exited, do: send(state.owner, {self(), {:exit_status, 1}})

    if state.closing do
      GenServer.reply(state.closing, true)
      {:stop, :normal, state}
    else
      {:noreply, %{state | exited: true}}
    end
  end

  def handle_info({:tcp_error, socket, _reason}, state), do: handle_info({:tcp_closed, socket}, state)

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{monitor: monitor} = state) do
    send_json(state.socket, %{op: "stop", grace_ms: 1_000})
    {:stop, :normal, state}
  end

  def handle_info(:close_timeout, state) do
    ProcessTree.graceful_kill_tree(state.metadata.relay_pid)
    GenServer.reply(state.closing, true)
    {:stop, :normal, state}
  end

  defp consume(data, state) do
    case :binary.split(data, "\n") do
      [line, rest] -> consume(rest, deliver(Jason.decode!(line), state))
      [pending] -> %{state | pending: pending}
    end
  end

  defp deliver(%{"op" => "frame", "offset" => offset, "line" => text} = frame, state) do
    line = if Map.has_key?(frame, "line_base64"), do: Base.decode64!(frame["line_base64"]), else: text
    deliver_line(state.owner, line)
    :ok = send_json(state.socket, %{op: "ack", offset: offset})
    %{state | metadata: Map.put(state.metadata, :acked_offset, offset)}
  end

  defp deliver(%{"op" => "exit", "status" => status}, state) do
    status = if status < 0, do: 128 - status, else: status
    send(state.owner, {self(), {:exit_status, status}})
    %{state | exited: true}
  end

  defp deliver(%{"op" => "error", "error" => reason}, state) do
    send(state.owner, {self(), {:exit_status, 1}})
    Logger.warning("relay controller error: #{inspect(reason)}")
    %{state | exited: true}
  end

  defp deliver_line(owner, line) when byte_size(line) > 1_048_576 do
    <<chunk::binary-size(1_048_576), rest::binary>> = line
    send(owner, {self(), {:data, {:noeol, chunk}}})
    deliver_line(owner, rest)
  end

  defp deliver_line(owner, line), do: send(owner, {self(), {:data, {:eol, line}}})
end

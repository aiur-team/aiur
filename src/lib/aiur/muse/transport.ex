defmodule Aiur.Muse.Transport do
  @moduledoc "Bounded native MSP transport, using Aiur's owned and scrubbed process launch."

  alias Aiur.AppServer.Adapter
  alias Aiur.ProcessTree

  @max_frame_bytes 4_194_304

  @spec start(Path.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start(workspace, command, opts \\ []) do
    cond do
      Keyword.get(opts, :worker_host) != nil -> {:error, :remote_worker_unsupported}
      not File.dir?(workspace) -> {:error, :workspace_not_found}
      true -> Adapter.start_port(workspace, command, &record_process(&1, opts), relay: false)
    end
  end

  @spec metadata(port()) :: map()
  def metadata(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        %{provider_pid: to_string(pid), agent_process_group_id: ProcessTree.process_group_for_pid(pid)}

      nil ->
        %{}
    end
  end

  @spec send_frame(port(), map()) :: :ok | {:error, :port_closed}
  def send_frame(port, frame) do
    true = Port.command(port, Jason.encode!(frame) <> "\n")
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  @spec request(port(), map(), pos_integer(), (map() -> term())) :: {:ok, map()} | {:error, term()}
  def request(port, %{"id" => id} = frame, timeout_ms, on_notification \\ fn _ -> :ok end) do
    with :ok <- send_frame(port, frame) do
      await_response(port, id, deadline(timeout_ms), on_notification)
    end
  end

  @spec receive_frame(port(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def receive_frame(port, timeout_ms), do: receive_until(port, deadline(timeout_ms), "")

  @spec decode_chunk(binary(), {:eol | :noeol, binary()}) ::
          {:ok, map()} | {:more, binary()} | {:error, atom()}
  def decode_chunk(pending, {_ending, chunk}) when byte_size(pending) + byte_size(chunk) > @max_frame_bytes,
    do: {:error, :frame_too_large}

  def decode_chunk(pending, {:noeol, chunk}), do: {:more, pending <> chunk}

  def decode_chunk(pending, {:eol, chunk}) do
    case Jason.decode(pending <> chunk) do
      {:ok, %{"jsonrpc" => "2.0"} = frame} -> {:ok, frame}
      _ -> {:error, :invalid_msp_frame}
    end
  end

  @spec stop(port()) :: :ok
  def stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> ProcessTree.graceful_kill_tree(pid)
      nil -> :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp record_process(port, opts) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    group = ProcessTree.process_group_for_pid(pid)
    provider = %{root_pid: pid, process_group_id: group, descendant_pids: ProcessTree.process_tree(pid)}
    provider_callback = Keyword.get(opts, :on_provider_started, fn _ -> :ok end)
    group_callback = Keyword.get(opts, :on_process_group_started, fn _ -> :ok end)

    with :ok <- provider_callback.(provider) do
      if is_integer(group), do: group_callback.(group), else: {:error, :process_group_unavailable}
    end
  end

  defp await_response(port, id, deadline, on_notification) do
    case receive_until(port, deadline, "") do
      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, {:msp_error, error}}

      {:ok, %{"id" => ^id, "result" => result}} when is_map(result) ->
        {:ok, result}

      {:ok, %{"id" => ^id}} ->
        {:error, :invalid_msp_response}

      {:ok, notification} ->
        on_notification.(notification)
        await_response(port, id, deadline, on_notification)

      {:error, _reason} = error ->
        error
    end
  end

  defp receive_until(port, deadline, pending) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :response_timeout}
    else
      receive_chunk(port, deadline, pending, remaining)
    end
  end

  defp receive_chunk(port, deadline, pending, remaining) do
    receive do
      {^port, {:data, chunk}} ->
        case decode_chunk(pending, chunk) do
          {:more, next} -> receive_until(port, deadline, next)
          result -> result
        end

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}

      # The port is unlinked: a write into closed stdin kills it with no exit status.
      {:DOWN, _ref, :port, ^port, reason} ->
        {:error, {:port_exit, reason}}
    after
      remaining -> {:error, :response_timeout}
    end
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
end

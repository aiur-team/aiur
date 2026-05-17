defmodule SymphonyElixir.IssueLog do
  @moduledoc """
  Per-issue file writer that captures the same transcript + alert stream
  the conversation pane shows. One GenServer per active issue; it
  subscribes to the agent's PubSub topic on startup and appends every
  event to `<logs-root>/log/<repo>.<issue>.log`.

  Multiple agent sessions on the same issue reuse the running writer —
  `attach/1` is idempotent. The writer stays alive until the BEAM exits;
  there's no automatic detach when the issue completes (the file is
  capped by disk, not by a watchdog), and the closed-then-reopened case
  is handled by the underlying `File.open([:append])`.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentEvents, AgentPubSub, Tracker}

  @supervisor SymphonyElixir.IssueLog.Supervisor

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: opts[:identifier],
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc """
  Ensure a writer is running for `identifier`. Returns `:ok` on success;
  if a writer is already running for this identifier the call is a
  no-op.
  """
  @spec attach(AgentEvents.agent_identifier()) :: :ok
  def attach(identifier) when is_binary(identifier) do
    case start_writer(identifier) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("IssueLog.attach(#{identifier}) failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Returns the resolved file path for an issue's log. Useful for tests
  and for users who want to `tail -F` a specific issue.
  """
  @spec log_path(AgentEvents.agent_identifier()) :: String.t()
  def log_path(identifier) when is_binary(identifier) do
    Path.join(log_root_dir(), "#{repo_name()}.#{sanitize(identifier)}.log")
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    GenServer.start_link(__MODULE__, identifier, name: via(identifier))
  end

  @impl true
  def init(identifier) do
    path = log_path(identifier)
    :ok = File.mkdir_p(Path.dirname(path))

    case File.open(path, [:append, :utf8]) do
      {:ok, file} ->
        :ok = AgentPubSub.subscribe_agent(identifier)
        Logger.debug("IssueLog attached identifier=#{identifier} path=#{path}")
        {:ok, %{identifier: identifier, file: file, path: path}}

      {:error, reason} ->
        Logger.warning("IssueLog open failed identifier=#{identifier} path=#{path} reason=#{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{file: file}) when not is_nil(file) do
    _ = File.close(file)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_info({:transcript_event, %{role: role, body: body} = event}, state) do
    write_line(state.file, format_transcript(role, body, event))
    {:noreply, state}
  end

  def handle_info({:alert, %{name: name, message: message} = event}, state) do
    write_line(state.file, format_alert(name, message, event))
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------- helpers ------------------------------------------------------

  defp start_writer(identifier) do
    DynamicSupervisor.start_child(
      @supervisor,
      {__MODULE__, identifier: identifier}
    )
  end

  defp via(identifier), do: {:via, Registry, {SymphonyElixir.IssueLog.Registry, identifier}}

  defp write_line(file, line) do
    IO.write(file, line)
  rescue
    _ -> :ok
  end

  defp format_transcript(role, body, event) do
    ts = timestamp(event)
    body_text = body |> to_string() |> String.replace("\r\n", "\n")
    "#{ts} #{role}: #{body_text}\n"
  end

  defp format_alert(name, message, event) do
    ts = timestamp(event)
    "#{ts} alert #{name}: #{message}\n"
  end

  defp timestamp(event) do
    case Map.get(event, :timestamp) do
      %DateTime{} = ts -> DateTime.to_iso8601(ts)
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp log_root_dir do
    case Application.get_env(:symphony_elixir, :log_file) do
      path when is_binary(path) -> Path.dirname(path)
      _ -> Path.join(File.cwd!(), "log")
    end
  end

  defp repo_name do
    case safe_project_identity() do
      identity when is_binary(identity) and identity != "" ->
        identity
        |> String.split("/")
        |> List.last()
        |> sanitize()
        |> default_if_empty()

      _ ->
        "symphony"
    end
  end

  defp safe_project_identity do
    Tracker.project_identity()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp sanitize(name) when is_binary(name) do
    String.replace(name, ~r/[^A-Za-z0-9._-]/, "_")
  end

  defp default_if_empty(""), do: "symphony"
  defp default_if_empty(value), do: value
end

defmodule Aiur.IssueSummaryLog do
  @moduledoc """
  Per-issue progress summary writer.

  The writer subscribes to the same structured agent topic as
  `Aiur.IssueLog`, plus the running/status topics used by the agent list.
  It turns high-signal events into one-line bullets at
  `<logs-root>/log/<repo>.<issue>.summary.log`.
  """

  use GenServer
  require Logger

  alias Aiur.{AgentEvents, AgentPubSub, Tracker}

  @supervisor Aiur.IssueSummaryLog.Supervisor
  @registry Aiur.IssueSummaryLog.Registry
  @max_recent_keys 100
  @max_lines 200

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: opts[:identifier],
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc """
  Ensure a summary writer is running for `identifier`.
  """
  @spec attach(AgentEvents.agent_identifier()) :: :ok
  def attach(identifier) when is_binary(identifier) do
    case start_writer(identifier) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("IssueSummaryLog.attach(#{identifier}) failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Returns the resolved summary log path for an issue.
  """
  @spec summary_path(AgentEvents.agent_identifier()) :: String.t()
  def summary_path(identifier) when is_binary(identifier) do
    Path.join(log_root_dir(), "#{repo_name()}.#{sanitize(identifier)}.summary.log")
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    GenServer.start_link(__MODULE__, identifier, name: via(identifier))
  end

  @impl true
  def init(identifier) do
    path = summary_path(identifier)
    :ok = File.mkdir_p(Path.dirname(path))
    {recent_keys, recent_key_set} = load_recent_keys(path)

    case File.open(path, [:append, :utf8]) do
      {:ok, file} ->
        :ok = AgentPubSub.subscribe_agent(identifier)
        :ok = AgentPubSub.subscribe_running()
        :ok = AgentPubSub.subscribe_status()

        Logger.debug("IssueSummaryLog attached identifier=#{identifier} path=#{path}")

        {:ok,
         %{
           identifier: identifier,
           file: file,
           path: path,
           line_count: count_existing_lines(path),
           recent_keys: recent_keys,
           recent_key_set: recent_key_set,
           last_running_status: nil
         }}

      {:error, reason} ->
        Logger.warning("IssueSummaryLog open failed identifier=#{identifier} path=#{path} reason=#{inspect(reason)}")

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
  def handle_info({:transcript_event, event}, state) do
    write_summary(summary_from_transcript(event), state)
  end

  def handle_info({:alert, event}, state) do
    write_summary(summary_from_alert(event), state)
  end

  def handle_info({:running_changed, summaries}, state) when is_list(summaries) do
    summary =
      Enum.find(summaries, fn
        %{identifier: identifier} -> identifier == state.identifier
        %{"identifier" => identifier} -> identifier == state.identifier
        _ -> false
      end)

    write_running_summary(summary, state)
  end

  def handle_info({:status_changed, %{identifier: identifier, status: status}}, state)
      when identifier == state.identifier do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> then(&write_summary({:status, "Agent status changed: #{&1}", DateTime.utc_now()}, state))
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp start_writer(identifier) do
    DynamicSupervisor.start_child(
      @supervisor,
      {__MODULE__, identifier: identifier}
    )
  end

  defp via(identifier), do: {:via, Registry, {@registry, identifier}}

  defp write_running_summary(nil, state), do: {:noreply, state}

  defp write_running_summary(summary, state) do
    status = Map.get(summary, :status) || Map.get(summary, "status")

    if status == state.last_running_status do
      {:noreply, state}
    else
      title = Map.get(summary, :title) || Map.get(summary, "title")
      message = running_message(status, title)

      case write_summary({:running, message, DateTime.utc_now()}, state) do
        {:noreply, next_state} -> {:noreply, %{next_state | last_running_status: status}}
      end
    end
  end

  defp running_message(:running, title), do: append_title("Agent running", title)
  defp running_message(:queued, title), do: append_title("Agent queued", title)
  defp running_message(status, title), do: append_title("Agent #{status}", title)

  defp append_title(message, title) when is_binary(title) and title != "",
    do: "#{message}: #{one_line(title, 120)}"

  defp append_title(message, _title), do: message

  defp write_summary(:skip, state), do: {:noreply, state}

  defp write_summary({_kind, message, timestamp}, state) when is_binary(message) do
    key = normalize_key(message)

    if MapSet.member?(state.recent_key_set, key) do
      {:noreply, state}
    else
      state = rotate_if_needed(state)
      line = "#{timestamp(timestamp)} - #{message}\n"
      write_line(state.file, line)
      {:noreply, remember_key(%{state | line_count: state.line_count + 1}, key)}
    end
  end

  defp summary_from_alert(%{name: name, message: message} = event)
       when is_binary(name) and is_binary(message) do
    {:alert, alert_message(name, message), event_timestamp(event)}
  end

  defp summary_from_alert(_event), do: :skip

  defp alert_message("phase.brainstorm.start", message), do: "Brainstorm started: #{one_line(message)}"
  defp alert_message("phase.brainstorm.end", message), do: "Brainstorm finished: #{one_line(message)}"
  defp alert_message("phase.plan.start", message), do: "Plan started: #{one_line(message)}"
  defp alert_message("phase.plan.end", message), do: "Plan finished: #{one_line(message)}"
  defp alert_message("phase.work.start", message), do: "Work started: #{one_line(message)}"
  defp alert_message("phase.work.end", message), do: "Work finished: #{one_line(message)}"
  defp alert_message("phase.review.start", message), do: "Review started: #{one_line(message)}"
  defp alert_message("phase.review.end", message), do: "Review finished: #{one_line(message)}"
  defp alert_message(name, message), do: "Alert #{name}: #{one_line(message)}"

  defp summary_from_transcript(%{role: :command, body: "$ " <> command} = event) do
    {:command, command_message(command), event_timestamp(event)}
  end

  defp summary_from_transcript(%{role: :assistant, body: body} = event) when is_binary(body) do
    {:assistant, "Agent reported: #{one_line(body)}", event_timestamp(event)}
  end

  defp summary_from_transcript(%{role: :system, body: body} = event) when is_binary(body) do
    if notable_system_message?(body) do
      {:system, "System noted: #{one_line(body)}", event_timestamp(event)}
    else
      :skip
    end
  end

  defp summary_from_transcript(%{role: :user, body: body} = event) when is_binary(body) do
    cond do
      String.starts_with?(body, "Coordination event:") ->
        {:user, "Coordination event received: #{one_line(body)}", event_timestamp(event)}

      String.length(String.trim(body)) <= 240 ->
        {:user, "Operator message received: #{one_line(body)}", event_timestamp(event)}

      true ->
        :skip
    end
  end

  defp summary_from_transcript(_event), do: :skip

  defp command_message(command) do
    cond do
      String.ends_with?(command, " [done]") ->
        command
        |> String.replace_suffix(" [done]", "")
        |> one_line()
        |> then(&"Command finished: #{&1}")

      match = Regex.run(~r/^(.*) \[exit=(\d+)\]$/, command) ->
        [_full, label, exit_code] = match
        "Command finished (exit #{exit_code}): #{one_line(label)}"

      true ->
        "Command started: #{one_line(command)}"
    end
  end

  defp notable_system_message?(body) do
    body
    |> String.downcase()
    |> String.contains?(["error", "failed", "paused", "resum", "stalled", "retry"])
  end

  defp remember_key(state, key) do
    queue = :queue.in(key, state.recent_keys)
    key_set = MapSet.put(state.recent_key_set, key)

    if :queue.len(queue) > @max_recent_keys do
      {{:value, old_key}, trimmed} = :queue.out(queue)
      %{state | recent_keys: trimmed, recent_key_set: MapSet.delete(key_set, old_key)}
    else
      %{state | recent_keys: queue, recent_key_set: key_set}
    end
  end

  defp rotate_if_needed(%{line_count: line_count} = state) when line_count < @max_lines, do: state

  defp rotate_if_needed(state) do
    _ = File.close(state.file)
    rotated_path = state.path <> ".1"
    _ = File.rm(rotated_path)
    _ = File.rename(state.path, rotated_path)

    case File.open(state.path, [:append, :utf8]) do
      {:ok, file} -> %{state | file: file, line_count: 0}
      {:error, _reason} -> %{state | line_count: 0}
    end
  end

  defp write_line(file, line) do
    IO.write(file, line)
  rescue
    _ -> :ok
  end

  defp count_existing_lines(path) do
    path
    |> File.stream!()
    |> Enum.count()
  rescue
    _ -> 0
  end

  defp load_recent_keys(path) do
    keys =
      path
      |> File.stream!()
      |> Enum.take(-@max_recent_keys)
      |> Enum.map(&summary_message/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&normalize_key/1)

    {Enum.reduce(keys, :queue.new(), &:queue.in/2), MapSet.new(keys)}
  rescue
    _ -> {:queue.new(), MapSet.new()}
  end

  defp summary_message(line) do
    line
    |> String.trim()
    |> String.split(" - ", parts: 2)
    |> case do
      [_timestamp, message] -> message
      [message] -> message
    end
  end

  defp one_line(text, limit \\ 180) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(limit)
  end

  defp truncate(text, limit) do
    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "..."
    else
      text
    end
  end

  defp normalize_key(message) do
    message
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp event_timestamp(event) do
    case Map.get(event, :timestamp) do
      %DateTime{} = ts -> ts
      _ -> DateTime.utc_now()
    end
  end

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp(_timestamp), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp log_root_dir do
    case Application.get_env(:aiur, :log_file) do
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
        "aiur"
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

  defp default_if_empty(""), do: "aiur"
  defp default_if_empty(value), do: value
end

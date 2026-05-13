defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single issue in its workspace with the configured coding agent.
  """

  require Logger
  alias SymphonyElixir.{CodingAgent, Config, Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue, workspace, worker_host) do
    fn message ->
      message = CodingAgent.normalize_event(message)
      write_agent_log(workspace, worker_host, message)
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    orchestrator = Keyword.get(opts, :orchestrator, SymphonyElixir.Orchestrator)

    with {:ok, session} <- CodingAgent.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          orchestrator,
          worker_host,
          1,
          max_turns
        )
      after
        CodingAgent.stop_session(session)
      end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         orchestrator,
         worker_host,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    message_handler = codex_message_handler(codex_update_recipient, issue, workspace, worker_host)

    with {:ok, turn_session} <-
           CodingAgent.run_turn(app_session, prompt, issue, on_message: message_handler),
         :ok <- drain_operator_messages(app_session, issue, message_handler, orchestrator) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            orchestrator,
            worker_host,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp drain_operator_messages(app_session, issue, message_handler, orchestrator) do
    receive do
      {:pause_agent, request_id} when is_integer(request_id) ->
        Logger.info("Pausing agent at next turn boundary for #{issue_context(issue)} request_id=#{request_id}")
        wait_for_operator_message(app_session, issue, message_handler, orchestrator)
    after
      0 -> drain_queued_operator_messages(app_session, issue, message_handler, orchestrator)
    end
  end

  defp wait_for_operator_message(app_session, issue, message_handler, orchestrator) do
    case claim_next_operator_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        Logger.info("Resuming paused agent for #{issue_context(issue)} request_id=#{item.id}")
        run_operator_turn(app_session, issue, item, message_handler, orchestrator)

      :empty ->
        receive do
          {:agent_queue_updated, issue_identifier, _item_id} when issue_identifier == issue.identifier ->
            wait_for_operator_message(app_session, issue, message_handler, orchestrator)

          {:pause_agent, request_id} when is_integer(request_id) ->
            Logger.info("Agent already paused for #{issue_context(issue)} request_id=#{request_id}")
            wait_for_operator_message(app_session, issue, message_handler, orchestrator)
        end
    end
  end

  defp drain_queued_operator_messages(app_session, issue, message_handler, orchestrator) do
    case claim_next_operator_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        Logger.info("Delivering operator message to #{issue_context(issue)} request_id=#{item.id}")
        run_operator_turn(app_session, issue, item, message_handler, orchestrator)

      :empty ->
        :ok
    end
  end

  defp claim_next_operator_item(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case SymphonyElixir.Orchestrator.claim_next_queue_item_for_test(orchestrator, issue_identifier) do
      {:ok, %{category: :operator_message} = item} -> {:ok, item}
      {:ok, _item} -> :empty
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  defp run_operator_turn(app_session, issue, item, message_handler, orchestrator) do
    text = item.body.text

    case CodingAgent.run_turn(app_session, text, issue, on_message: message_handler) do
      {:ok, _turn_session} ->
        :ok = SymphonyElixir.Orchestrator.mark_queue_item_consumed_for_test(orchestrator, item.id)
        drain_operator_messages(app_session, issue, message_handler, orchestrator)

      {:error, reason} = error ->
        :ok = SymphonyElixir.Orchestrator.mark_queue_item_failed_for_test(orchestrator, item.id, reason)
        error
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp write_agent_log(_workspace, worker_host, _message) when is_binary(worker_host), do: :ok

  defp write_agent_log(workspace, nil, message) when is_binary(workspace) and is_map(message) do
    log_dir = Path.join(workspace, "logs")
    ndjson_path = Path.join(log_dir, "agent.ndjson")
    markdown_path = Path.join(log_dir, "agent.md")

    with :ok <- File.mkdir_p(log_dir),
         :ok <- File.write(ndjson_path, Jason.encode!(json_safe(message)) <> "\n", [:append]),
         :ok <- File.write(markdown_path, markdown_entry(message), [:append]) do
      :ok
    else
      {:error, reason} ->
        Logger.debug("Failed writing agent log workspace=#{workspace} reason=#{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.debug("Failed writing agent log workspace=#{workspace} error=#{Exception.message(error)}")
      :ok
  end

  defp write_agent_log(_workspace, _worker_host, _message), do: :ok

  defp markdown_entry(message) do
    timestamp =
      message
      |> Map.get(:timestamp, DateTime.utc_now())
      |> format_timestamp()

    event = Map.get(message, :event) || Map.get(message, "event") || "event"
    summary = event_summary(message)

    """
    ## #{timestamp} #{event}

    #{summary}

    """
  end

  defp event_summary(message) do
    cond do
      is_binary(message[:last_message]) -> message[:last_message]
      is_binary(message["last_message"]) -> message["last_message"]
      is_binary(message[:raw]) -> code_block(message[:raw])
      is_binary(message["raw"]) -> code_block(message["raw"])
      true -> code_block(inspect(Map.drop(message, [:timestamp])))
    end
  end

  defp code_block(value) do
    """
    ```text
    #{value}
    ```
    """
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%{} = value), do: Map.new(value, fn {key, val} -> {json_safe_key(key), json_safe(val)} end)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key), do: to_string(key)

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp format_timestamp(_timestamp), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end

defmodule Aiur.TestReset.Tickets do
  @moduledoc false

  alias Aiur.GitHub.{HostCommand, Labels}
  alias Aiur.TestReset

  @type gh_runner :: Aiur.TestReset.gh_runner()

  @doc false
  @spec prepare_reset_ticket(integer() | String.t(), gh_runner()) ::
          :open | {:closed, [String.t()]} | {:error, String.t()}
  def prepare_reset_ticket(id, runner) do
    case fetch_issue_metadata(id, runner) do
      {:ok, %{state: state, labels: labels}} ->
        cond do
          open_issue_state?(state) ->
            :open

          closed_issue_state?(state) ->
            id |> clear_closed_ticket_automation_labels(labels, runner) |> reopen_closed_ticket(id, runner)

          true ->
            {:error, "unexpected GitHub issue state #{inspect(state)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec issue_metadata_command_args(integer() | String.t()) :: [String.t()]
  def issue_metadata_command_args(id) do
    ["issue", "view", to_string(id), "--json", "state,labels"]
  end

  @spec automation_label_cleanup_command_args(integer() | String.t(), [String.t()]) ::
          [String.t()] | nil
  def automation_label_cleanup_command_args(id, labels) do
    case automation_labels(labels) do
      [] -> nil
      automation -> ["issue", "edit", to_string(id), "--remove-label", Enum.join(automation, ",")]
    end
  end

  @spec automation_labels([term()]) :: [String.t()]
  def automation_labels(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn label ->
      case label_name(label) do
        "agent:" <> _ = name -> [name]
        "model:" <> _ = name -> [name]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  def automation_labels(_), do: []

  defp fetch_issue_metadata(id, runner) do
    case runner.(issue_metadata_command_args(id)) do
      {output, 0} ->
        decode_issue_metadata(output)

      {output, _code} ->
        {:error, String.trim(to_string(output))}
    end
  end

  defp decode_issue_metadata(output) do
    case Jason.decode(output) do
      {:ok, %{"state" => state} = data} ->
        labels = Map.get(data, "labels", []) |> Enum.flat_map(&metadata_label_name/1)
        {:ok, %{state: state, labels: labels}}

      {:ok, _} ->
        {:error, "could not parse GitHub issue metadata"}

      {:error, _reason} ->
        {:error, "could not parse GitHub issue metadata"}
    end
  end

  defp metadata_label_name(%{"name" => name}) when is_binary(name), do: [name]
  defp metadata_label_name(name) when is_binary(name), do: [name]
  defp metadata_label_name(_), do: []

  defp label_name(%{"name" => name}) when is_binary(name), do: name
  defp label_name(name) when is_binary(name), do: name
  defp label_name(_), do: nil

  defp open_issue_state?(state), do: normalize_issue_state(state) == "open"
  defp closed_issue_state?(state), do: normalize_issue_state(state) == "closed"

  defp normalize_issue_state(state) do
    state
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp clear_closed_ticket_automation_labels(id, labels, runner) do
    case automation_label_cleanup_command_args(id, labels) do
      nil ->
        TestReset.warn("##{id} closed ticket; no automation labels found")
        {:closed, []}

      argv ->
        automation = automation_labels(labels)

        case runner.(argv) do
          {_, 0} ->
            TestReset.warn("##{id} closed ticket; removed automation labels: #{Enum.join(automation, ",")}")
            {:closed, automation}

          {output, _code} ->
            {:error, "closed ticket automation label cleanup failed: #{String.trim(to_string(output))}"}
        end
    end
  end

  # A smoke run can leave its sandbox ticket closed; reopen it so the next
  # `--test` resets it instead of aborting (#5121).
  defp reopen_closed_ticket({:closed, _labels} = closed, id, runner) do
    case runner.(reopen_command_args(id)) do
      {_, 0} ->
        TestReset.ok("##{id} reopened closed sandbox ticket")
        :open

      {output, _code} ->
        TestReset.warn("##{id} reopen failed: #{String.trim(to_string(output))}")
        closed
    end
  end

  defp reopen_closed_ticket(error, _id, _runner), do: error

  @spec reopen_command_args(integer() | String.t()) :: [String.t()]
  def reopen_command_args(id), do: ["issue", "reopen", to_string(id)]

  # Strip every agent:* label and re-add agent:todo so the orchestrator
  # treats the issue as queued on the next dispatch poll. Without this,
  # tickets that the previous run flipped to agent:in-progress (or
  # agent:human-review, agent:done) stay in that state and either
  # never re-enter the dispatch set or skip the queue logic entirely.
  #
  # Issue this as TWO `gh` calls: one to strip every agent:* label,
  # then one to add agent:todo. The combined form
  # `gh issue edit N --remove-label "agent:todo,…" --add-label "agent:todo"`
  # is unsafe — when the same label appears in both the remove and add
  # sets, GitHub's PATCH ordering resolves the remove last, stripping
  # the label entirely. That left issues in an unlabeled state, which
  # made the orchestrator skip dispatching them and the user's chat
  # pane render no agent text (no codex turn → no transcript events).
  # GitHub's GraphQL endpoint intermittently 401s during a reset (and its
  # label index lags), so a single `gh issue edit` attempt is flaky. When it
  # fails, the ticket is left without `agent:todo` and the orchestrator never
  # dispatches it — for the 3-ticket blocker chain that strands the whole run
  # (e.g. #101 opens its PR then pauses forever waiting on the never-dispatched
  # #100, timing out ~90 min later). Retry a few times, then return an error so
  # the caller refuses to launch a run that can't dispatch this ticket.
  @label_reset_attempts 3
  @label_reset_backoff_ms 1_500

  @doc false
  @spec reset_labels(integer() | String.t()) :: :ok | {:error, {:label_reset_failed, integer() | String.t(), String.t()}}
  def reset_labels(id) do
    [remove_argv, add_argv] = reset_labels_command_args(id)
    runner = fn argv -> HostCommand.run(argv, stderr_to_stdout: true, bot_token: true) end

    case apply_label_reset(remove_argv, add_argv, runner, @label_reset_attempts, @label_reset_backoff_ms) do
      :ok ->
        TestReset.ok("##{id} labels prepared on open ticket → agent:todo")
        :ok

      {:error, output} ->
        TestReset.warn("##{id} label reset FAILED after #{@label_reset_attempts} attempts: #{output}")
        {:error, {:label_reset_failed, id, output}}
    end
  end

  @doc false
  @spec apply_label_reset([String.t()], [String.t()], gh_runner(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, String.t()}
  def apply_label_reset(remove_argv, add_argv, runner, attempts, backoff_ms)
      when attempts > 0 do
    with {_, 0} <- runner.(remove_argv),
         {_, 0} <- runner.(add_argv) do
      :ok
    else
      {_output, _code} when attempts > 1 ->
        if backoff_ms > 0, do: Process.sleep(backoff_ms)
        apply_label_reset(remove_argv, add_argv, runner, attempts - 1, backoff_ms)

      {output, _code} ->
        {:error, String.trim(to_string(output))}
    end
  end

  @doc false
  @spec reset_labels_command_args(integer() | String.t()) :: [[String.t()]]
  def reset_labels_command_args(id) do
    reset_labels =
      Labels.state_labels("agent") ++
        Labels.paused_labels("agent") ++ Labels.queued_labels("agent") ++ Labels.required_rate_limit_fallback_labels("agent")

    [
      ["issue", "edit", to_string(id), "--remove-label", Enum.join(reset_labels, ",")],
      ["issue", "edit", to_string(id), "--add-label", "agent:todo"]
    ]
  end
end

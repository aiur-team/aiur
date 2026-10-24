defmodule Aiur.Orchestrator.PushRouting.PrBodyEvidence do
  @moduledoc false

  require Logger

  alias Aiur.{AlertFeed, Alerts, Issue}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator.{State, TicketTransition, TrackerTasks}

  @doc false
  @spec check(State.t(), String.t() | integer(), map(), keyword()) :: State.t()
  def check(%State{} = state, identifier, event, opts) do
    client = Application.get_env(:aiur, :github_client_module, GitHubClient)

    fetcher =
      Keyword.get(opts, :pull_request_fetcher) ||
        fn number -> client.fetch_open_pull_request_for_branch(number) end

    identifier = to_string(identifier)

    with {issue_number, ""} <- Integer.parse(identifier),
         %{sha: pushed_sha} when is_binary(pushed_sha) <- branch_push_metadata(event),
         {:ok, %{} = pr} <- fetcher.(issue_number),
         {pr_number, ""} <- Integer.parse(to_string(value(pr, :number))),
         head_sha when is_binary(head_sha) <- nested_value(pr, :head, :sha),
         body when is_binary(body) <- value(pr, :body) do
      if tested_head_matches?(body, head_sha) do
        state
        |> resolve_stale_alert(identifier, opts)
        |> write_body_fix_reason(identifier, :remove, opts)
      else
        state
        |> emit_stale_alert(identifier, pr_number, head_sha, opts)
        |> write_body_fix_reason(identifier, :add, opts)
      end
    else
      _ -> state
    end
  rescue
    _ -> state
  end

  defp branch_push_metadata(%{payload: payload}) when is_map(payload), do: branch_push_metadata(payload)
  defp branch_push_metadata(%{"payload" => payload}) when is_map(payload), do: branch_push_metadata(payload)

  defp branch_push_metadata(event) when is_map(event),
    do: %{sha: Map.get(event, :sha) || Map.get(event, "sha")}

  defp branch_push_metadata(_event), do: %{sha: nil}

  defp nested_value(map, outer, inner) do
    case value(map, outer) do
      nested when is_map(nested) -> value(nested, inner)
      _ -> nil
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp tested_head_matches?(body, sha),
    do: Regex.match?(~r/(?m)^Tested head: #{Regex.escape(sha)}\s*$/, body)

  defp emit_stale_alert(state, identifier, pr_number, pushed_sha, opts) do
    topic = "ticket.#{identifier}.pr.tested_head_stale"
    condition_state = Keyword.get(opts, :condition_state, &AlertFeed.condition_state/1)

    if condition_state.(topic) == :firing do
      state
    else
      emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

      _ =
        emitter.(topic,
          issue: %Issue{id: identifier, identifier: identifier},
          message: "PR ##{pr_number} has stale Tested head evidence after push #{String.slice(pushed_sha, 0, 12)}",
          reason: "Refresh the PR body's Tested head to the pushed SHA and rerun check-pr-body before handoff.",
          needs_attention: true,
          severity: "warning",
          central: true
        )

      state
    end
  end

  defp resolve_stale_alert(state, identifier, opts) do
    condition = "ticket.#{identifier}.pr.tested_head_stale"
    condition_state = Keyword.get(opts, :condition_state, &AlertFeed.condition_state/1)

    if condition_state.(condition) == :firing do
      emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

      _ =
        emitter.(condition <> ".resolved",
          issue: %Issue{id: identifier, identifier: identifier},
          message: "PR body Tested head now matches the live head",
          reason: "The stale Tested head evidence has been refreshed.",
          needs_attention: false,
          severity: "info",
          central: true
        )
    end

    state
  end

  defp write_body_fix_reason(state, identifier, action, opts) do
    writer =
      Keyword.get(opts, :reason_label_writer, fn id, action ->
        TicketTransition.write_reason_modifier(id, action, "body-fix", writer: :pr_body_evidence)
      end)

    TrackerTasks.chain(state, {:runtime_reason_labels, identifier}, fn -> writer.(identifier, action) end, fn current, result ->
      case result do
        :ok ->
          current

        {:error, reason} ->
          Logger.warning("body-fix reason label update failed: issue=#{identifier} reason=#{inspect(reason)}")
          current
      end
    end)
  end
end

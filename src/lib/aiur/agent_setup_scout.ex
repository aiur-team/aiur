defmodule Aiur.AgentSetupScout do
  @moduledoc """
  Repo-agnostic setup-friction detector for agent transcripts.

  The scout looks for repeated workflow friction patterns rather than
  hardcoded Aiur-specific failures. It returns findings for an injected
  reporter; callers decide how and when to file them.
  """

  @env_threshold 3
  @poll_threshold 3

  defstruct buckets: %{}, reported: MapSet.new()

  @type t :: %__MODULE__{buckets: map(), reported: MapSet.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec observe(t(), String.t(), map()) :: {t(), [map()]}
  def observe(%__MODULE__{} = state, identifier, event)
      when is_binary(identifier) and is_map(event) do
    event
    |> detectors()
    |> Enum.reduce({state, []}, fn detector, {acc_state, findings} ->
      {next_state, new_findings} = apply_detector(acc_state, identifier, event, detector)
      {next_state, findings ++ new_findings}
    end)
  end

  defp detectors(%{role: :command}), do: [:env_prefix, :polling]
  defp detectors(%{role: :system}), do: [:tool_not_found, :idle_loop]
  defp detectors(%{role: :assistant}), do: [:tool_not_found, :idle_loop]
  defp detectors(%{role: :tool}), do: [:tool_not_found]
  defp detectors(_event), do: []

  defp apply_detector(state, identifier, event, :env_prefix) do
    vars = env_prefix_vars(body(event))

    Enum.reduce(vars, {state, []}, fn vars_key, {acc_state, findings} ->
      record_threshold(
        acc_state,
        {:env_prefix, identifier, vars_key},
        event,
        @env_threshold,
        fn evidence ->
          finding(
            identifier,
            "Pre-seed #{vars_key} for agent commands",
            "Agents repeatedly set #{vars_key} inline on commands.",
            evidence,
            "Pre-seed #{vars_key} in the workspace hook or runtime environment so agents do not redeclare it per command."
          )
        end,
        findings
      )
    end)
  end

  defp apply_detector(state, identifier, event, :polling) do
    command = normalize_command(body(event))

    if polling_command?(command) do
      record_threshold(
        state,
        {:polling, identifier, command},
        event,
        @poll_threshold,
        fn evidence ->
          finding(
            identifier,
            "Subscribe instead of polling #{poll_resource(command)}",
            "Agent repeatedly polled the same external resource with no visible state change.",
            evidence,
            "Subscribe to events from #{poll_resource(command)} or add a backoff-aware state watcher."
          )
        end,
        []
      )
    else
      {state, []}
    end
  end

  defp apply_detector(state, identifier, event, :tool_not_found) do
    case missing_tool(body(event)) do
      nil ->
        {state, []}

      tool ->
        record_threshold(
          state,
          {:tool_not_found, identifier, tool},
          event,
          1,
          fn evidence ->
            finding(
              identifier,
              "Install #{tool} for agent workspaces",
              "Agent hit a missing tool and had to continue with a fallback.",
              evidence,
              "Install #{tool} in the workspace toolchain or document the supported replacement in the agent prompt."
            )
          end,
          []
        )
    end
  end

  defp apply_detector(state, identifier, event, :idle_loop) do
    if body(event) =~ ~r/\bcontinuation #?\d+\b/i do
      record_threshold(
        state,
        {:idle_loop, identifier},
        event,
        1,
        fn evidence ->
          finding(
            identifier,
            "Stop idle continuation loop for #{identifier}",
            "Agent logged continuation turns with no actionable state change.",
            evidence,
            "Remove the completed label or state from active runtime states so the agent turn loop ends cleanly."
          )
        end,
        []
      )
    else
      {state, []}
    end
  end

  defp record_threshold(state, key, event, threshold, build_finding, existing_findings) do
    evidence = Map.get(state.buckets, key, []) ++ [evidence(event)]
    state = %{state | buckets: Map.put(state.buckets, key, evidence)}

    if length(evidence) >= threshold and not MapSet.member?(state.reported, key) do
      finding = build_finding.(evidence)
      {%{state | reported: MapSet.put(state.reported, key)}, existing_findings ++ [finding]}
    else
      {state, existing_findings}
    end
  end

  defp finding(identifier, title, pattern, evidence, suggested_fix) do
    %{
      identifier: identifier,
      title: title,
      labels: ["enhancement", "agent-setup-optimization", "needs-triage"],
      body: body(pattern, evidence, suggested_fix)
    }
  end

  defp body(pattern, evidence, suggested_fix) do
    timestamps = Enum.map(evidence, & &1.timestamp) |> Enum.reject(&is_nil/1)
    range = timestamp_range(timestamps)
    count = length(evidence)
    samples = evidence |> Enum.take(-5) |> Enum.map_join("\n", &"- #{&1.sample}")

    """
    ## Pattern observed

    #{pattern}

    ## Evidence

    Count: #{count}
    Timestamp range: #{range}

    #{samples}

    ## Suggested fix

    #{suggested_fix}

    ## Caveat

    This optimization is specific to this repo's language/framework. Other deployments will need analogous fixes targeted at their stack.
    """
    |> String.trim()
  end

  defp evidence(event) do
    %{
      timestamp: timestamp(event),
      sample: body(event) |> summarize(180)
    }
  end

  defp env_prefix_vars(command) do
    ~r/(?:^|\s)((?:[A-Z][A-Z0-9_]*=(?:"[^"]+"|'[^']+'|[^\s]+)\s*){1,})/
    |> Regex.scan(command)
    |> Enum.map(fn [_, segment] ->
      segment
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(fn assignment -> assignment |> String.split("=", parts: 2) |> hd() end)
      |> Enum.sort()
      |> Enum.join(", ")
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp missing_tool(text) do
    cond do
      match = Regex.run(~r/\b([A-Za-z0-9_.-]+): command not found\b/i, text) ->
        Enum.at(match, 1)

      match = Regex.run(~r/\bcommand not found: ([A-Za-z0-9_.-]+)\b/i, text) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  defp polling_command?(command) do
    command =~ ~r/\b(gh|git|curl|mix|npm|pnpm|yarn)\b/ and
      command =~ ~r/\b(view|status|ls-remote|check|list|show)\b/
  end

  defp poll_resource(command) do
    command
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(3)
    |> Enum.join(" ")
  end

  defp normalize_command(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp body(event), do: Map.get(event, :body, "") |> to_string()

  defp timestamp(%{timestamp: %DateTime{} = ts}), do: DateTime.to_iso8601(ts)
  defp timestamp(_), do: nil

  defp timestamp_range([]), do: "unknown"
  defp timestamp_range([one]), do: one

  defp timestamp_range(timestamps) do
    "#{Enum.min(timestamps)} to #{Enum.max(timestamps)}"
  end

  defp summarize(text, limit) do
    single = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(single) > limit do
      String.slice(single, 0, limit) <> "..."
    else
      single
    end
  end
end

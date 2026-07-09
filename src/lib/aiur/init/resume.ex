defmodule Aiur.Init.Resume do
  @moduledoc """
  Saved-config readback for a resume run — the saved-selections summary and the tracker/agents/routing readback from an existing config.
  """

  alias Aiur.Init.Questions

  @spec print_saved_summary(Aiur.Init.io(), map()) :: :ok
  def print_saved_summary(io, config) do
    io.puts.("✅ Saved selections:")

    Enum.each(saved_summary_lines(config), fn line ->
      io.puts.(IO.ANSI.format([:faint, "  " <> line]))
    end)
  end

  @spec saved_summary_lines(map()) :: [String.t()]
  def saved_summary_lines(config) do
    agent = config["agent"] || %{}
    tracker = config["tracker"] || %{}
    github = tracker["github"] || %{}
    workspace = config["workspace"] || %{}
    polling = config["polling"] || %{}
    permission_mode = get_in(agent, ["claude", "permission_mode"])

    [
      "tracker: #{tracker["kind"]}",
      github["repo"] && "repo: #{github["repo"]}",
      "agent: #{agent["kind"]}",
      "routing: #{format_routing(agent["routing"])}",
      permission_mode && "permission_mode: #{permission_mode}",
      "max_concurrent_agents: #{agent["max_concurrent_agents"]}",
      "max_turns: #{agent["max_turns"]}",
      "max_agent_duration_minutes: #{agent["max_agent_duration_minutes"]}",
      "workspace_root: #{workspace["root"]}",
      "pre_warmed_sessions: #{config["pre_warmed_sessions"]}",
      "polling_interval_seconds: #{polling["interval_seconds"]}",
      alerts_summary_line(config),
      config["prompt_file"] && "prompt_file: #{config["prompt_file"]}"
    ]
    |> Enum.reject(&is_nil/1)
  end

  @spec alerts_summary_line(map()) :: String.t() | nil
  def alerts_summary_line(config) do
    case config["alerts"] do
      %{"enabled" => enabled} -> "alerts: #{enabled}"
      _ -> nil
    end
  end

  @spec format_routing(map() | term()) :: String.t()
  def format_routing(routing) when is_map(routing) do
    routing
    |> Enum.sort_by(fn {level, _} -> to_string(level) end)
    |> Enum.map_join(", ", fn {level, value} -> "#{level}:#{value}" end)
  end

  def format_routing(_routing), do: ""

  @spec tracker_from_config(Aiur.Init.deps(), map()) :: map()
  def tracker_from_config(deps, config) do
    tracker = config["tracker"] || %{}

    case tracker["kind"] do
      "github" ->
        repo = get_in(config, ["tracker", "github", "repo"]) || deps.detect_repo.()
        %{kind: "github", repo: repo}

      "linear" ->
        %{
          kind: "linear",
          api_key: get_in(config, ["tracker", "linear", "api_key"]),
          project_slug: get_in(config, ["tracker", "linear", "project_slug"])
        }

      kind ->
        %{kind: kind}
    end
  end

  # Backends to provision labels for: the default agent kind plus any backend
  # named in the routing table (e.g. `claude:sonnet` -> `claude`).
  @spec agents_from_config(map()) :: [String.t()]
  def agents_from_config(config) do
    agent = config["agent"] || %{}
    routing_backends = (agent["routing"] || %{}) |> Map.values() |> Enum.map(&routing_backend/1)

    [agent["kind"] | routing_backends]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Questions.agent_kinds()
  end

  @spec routing_backend(term()) :: String.t()
  def routing_backend(value), do: value |> to_string() |> String.split(":") |> hd()
end

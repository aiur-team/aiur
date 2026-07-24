defmodule Aiur.Init.Questions do
  @moduledoc "The core wizard prompts and their pure parse/normalize policy (location, tracker, agents, complexity routing, permission mode, numeric/\"none\" limits, agent-kind ordering)."

  alias Aiur.CodingAgent
  alias Aiur.Init.Format

  @tracker_kinds ["github", "linear"]
  @permission_modes ["bypassPermissions", "default (coming soon)", "acceptEdits (coming soon)"]
  # Low complexity routes to the first kind, high to the last.
  @routing_order ["claude", "codex"]

  @spec workspace_default(map()) :: String.t()
  def workspace_default(%{kind: "github", repo: repo}) when is_binary(repo) and repo != "",
    do: "~/.aiur/workspaces/" <> repo

  def workspace_default(_tracker), do: "~/.aiur/workspaces"

  @spec prompt_location(Aiur.Init.io()) :: :global | :repo_local
  def prompt_location(io) do
    options = ["repo (./.aiur/)", "global (~/.aiur/)"]

    case Format.value_of(io.select.("Where will you store aiur settings for this project?", options, hd(options))) do
      "global" -> :global
      _ -> :repo_local
    end
  end

  @spec prompt_tracker(Aiur.Init.io(), Aiur.Init.deps(), atom()) :: map()
  def prompt_tracker(io, deps, location) do
    case io.select.("Issue tracker", @tracker_kinds, "github") do
      "github" ->
        # The global config is general, so it omits the repo (auto-detected
        # from the git remote of whatever repo aiur runs in).
        repo = if location == :global, do: nil, else: io.input.("GitHub repo (owner/name)", deps.detect_repo.(), nil)
        %{kind: "github", repo: repo}

      "linear" ->
        %{
          kind: "linear",
          api_key: io.input.("Linear API key", nil, nil),
          project_slug: io.input.("Linear project slug", nil, nil)
        }
    end
  end

  @spec prompt_agents(Aiur.Init.io()) :: [String.t()]
  def prompt_agents(io) do
    choices = agent_kind_choices()

    selected =
      case io.multiselect.("Which agents to support", choices, ["claude"]) do
        [] -> [List.first(choices)]
        kinds -> kinds
      end

    agent_kinds(selected)
  end

  @spec prompt_routing(Aiur.Init.io(), [String.t()]) :: map()
  def prompt_routing(io, agents) do
    primary = primary_kind(agents)

    io.puts.("Aiur supports story point complexity tags to optimize agent effort per ticket.")

    if io.confirm.("Would you like to select models and effort for 5 complexity tags?", false) do
      io.puts.("Select backend, model, and effort for issues with the following story points (1-5):")
      Map.new(1..5, fn level -> {level, prompt_routing_level(io, agents, level, primary)} end)
    else
      Map.new(1..5, fn level -> {level, primary} end)
    end
  end

  @spec prompt_rate_limit_fallback(Aiur.Init.io(), [String.t()]) :: [String.t()]
  def prompt_rate_limit_fallback(io, agents) do
    if length(agents) > 1 and io.confirm.("Switch to another configured agent when a usage limit is reached?", false) do
      io.multiselect.("Fallback priority (first available wins)", agents, agents)
    else
      []
    end
  end

  @spec routing_value(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def routing_value(backend, nil, nil), do: backend
  def routing_value(backend, model, nil), do: "#{backend}:#{model}"
  def routing_value(backend, nil, effort), do: "#{backend}::#{effort}"
  def routing_value(backend, model, effort), do: "#{backend}:#{model}:#{effort}"

  @spec prompt_permission_mode(Aiur.Init.io()) :: String.t()
  def prompt_permission_mode(io) do
    case io.select.("Claude permission mode", @permission_modes, "bypassPermissions") do
      "bypassPermissions" ->
        "bypassPermissions"

      other ->
        io.puts.("⚠️ #{other} needs an approval UI (coming soon) — using bypassPermissions.")
        "bypassPermissions"
    end
  end

  @spec prompt_int(Aiur.Init.io(), String.t(), integer(), integer(), String.t() | nil) :: integer()
  def prompt_int(io, label, default, min, hint \\ nil) do
    case Integer.parse(to_string(io.input.(label, Integer.to_string(default), hint))) do
      {n, ""} when n >= min ->
        n

      _ ->
        io.puts.("Enter a whole number ≥ #{min}.")
        prompt_int(io, label, default, min, hint)
    end
  end

  @spec prompt_max_turns(Aiur.Init.io()) :: non_neg_integer() | String.t()
  def prompt_max_turns(io) do
    case normalize_int_or_none(io.input.("Max turns per issue", "none", "none = unlimited")) do
      :none ->
        "none"

      n when is_integer(n) ->
        n

      :invalid ->
        io.puts.("Enter a whole number ≥ 1, or `none`.")
        prompt_max_turns(io)
    end
  end

  @spec prompt_max_duration(Aiur.Init.io()) :: non_neg_integer()
  def prompt_max_duration(io) do
    case normalize_int_or_none(io.input.("Max agent duration in minutes", "60", "Safety checkpoint: none = never auto-pause")) do
      :none ->
        0

      n when is_integer(n) ->
        n

      :invalid ->
        io.puts.("Enter a whole number ≥ 1, or `none`.")
        prompt_max_duration(io)
    end
  end

  @spec normalize_int_or_none(term()) :: pos_integer() | :invalid | :none
  def normalize_int_or_none(value) do
    trimmed = value |> to_string() |> String.trim()

    if String.downcase(trimmed) in ["none", "unlimited", ""] do
      :none
    else
      case Integer.parse(trimmed) do
        {n, ""} when n >= 1 -> n
        _ -> :invalid
      end
    end
  end

  @spec agent_kind_choices() :: [String.t()]
  def agent_kind_choices do
    Enum.filter(@routing_order, &(&1 in known_agent_kinds()))
  end

  @spec primary_kind([String.t()]) :: String.t()
  def primary_kind(agents), do: hd(agent_kinds(agents))

  @spec agent_kinds([String.t()]) :: [String.t()]
  def agent_kinds(kinds) when is_list(kinds) do
    kinds
    |> Enum.uniq()
    |> Enum.sort_by(&Enum.find_index(@routing_order, fn k -> k == &1 end))
  end

  @doc false
  @spec known_agent_kinds() :: [String.t()]
  def known_agent_kinds, do: CodingAgent.known_backends()

  defp prompt_routing_level(io, agents, level, primary) do
    backend = io.select.("complexity:#{level} backend", agents, primary) |> Format.value_of()
    model = prompt_routing_model(io, backend, level)
    effort = prompt_routing_effort(io, backend, level)

    routing_value(backend, model, effort)
  end

  # Generic family tags lead the list, so the routing table an Executor builds
  # here defaults to "newest in this family" instead of a version that expires.
  defp prompt_routing_model(io, backend, level) do
    models = CodingAgent.seedable_models(backend)

    case io.select.("complexity:#{level} #{backend} model", ["default model" | models], "default model") |> Format.value_of() do
      "default model" -> nil
      model -> model
    end
  end

  defp prompt_routing_effort(io, backend, level) do
    case CodingAgent.efforts(backend) do
      [] ->
        nil

      efforts ->
        case io.select.("complexity:#{level} #{backend} effort", ["default effort" | efforts], "default effort") |> Format.value_of() do
          "default effort" -> nil
          effort -> effort
        end
    end
  end
end

defmodule Aiur.Init do
  @moduledoc """
  Interactive `aiur init` wizard.

  The wizard takes an injected `io` (prompt/print) and `deps` (filesystem,
  network, auth) so it is fully unit-testable with no real side effects.
  """

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage
  alias Aiur.Init.Alerts
  alias Aiur.Init.ElevenLabs
  alias Aiur.Init.Format
  alias Aiur.Init.Prewarm
  alias Aiur.Init.Questions
  alias Aiur.Init.Resume
  alias Aiur.Init.Runtime
  alias Aiur.Init.Scaffold
  alias Aiur.Init.Templates

  @prompt_basename "prompt.md"
  @env_file_name ".env"
  @token_url "https://github.com/settings/tokens"
  @linear_key_url "https://linear.app/settings/api"

  @type io :: Aiur.Init.Runtime.io()
  @type deps :: Aiur.Init.Runtime.deps()

  @spec run(%{force: boolean()}) :: :ok | {:error, String.t()}
  def run(opts) do
    Aiur.Init.Dotenv.load()
    Runtime.ensure_http_client()
    run(opts, Runtime.runtime_io(), runtime_deps())
  end

  @spec run(%{force: boolean()}, io(), deps()) :: :ok | {:error, String.t()}
  def run(opts, io, deps) do
    io.puts.(init_warning())

    case existing_config_target(opts, deps) do
      nil ->
        location = Questions.prompt_location(io)
        fresh_setup(io, deps, location, deps.config_target.(location))

      target ->
        resume(io, deps, target)
    end
  end

  defp init_warning do
    "⚠️  Use at your own risk: aiur bypasses all agent permissions, is an unstable preview, and " <>
      "has minimal token-efficiency optimization. Best for simple tasks under supervision.\n"
  end

  defp existing_config_target(%{force: true}, _deps), do: nil

  defp existing_config_target(_opts, deps) do
    Enum.find_value(config_probe_targets(deps), fn {kind, location, path} ->
      if found = deps.existing_config_path.(path), do: {kind, location, found}
    end)
  end

  defp config_probe_targets(deps) do
    [
      {:new, :repo_local, deps.config_target.(:repo_local)},
      {:legacy, :repo_local, deps.legacy_config_target.(:repo_local)},
      {:new, :global, deps.config_target.(:global)},
      {:legacy, :global, deps.legacy_config_target.(:global)}
    ]
  end

  defp resume(_io, deps, {:legacy, location, target}) do
    canonical = deps.config_target.(location)

    {:error,
     "#{target} is no longer supported. " <>
       "Move it to #{canonical} before running `aiur init` again. " <>
       "Keep relative prompt_file and hooks_file paths valid from the new config directory."}
  end

  defp resume(io, deps, {:new, location, target}) do
    case deps.load_config.(target) do
      {:ok, config} ->
        io.puts.("Found an existing config at #{target}; resuming setup.")
        Resume.print_saved_summary(io, config)
        tracker = Resume.tracker_from_config(deps, config, config_path: target)

        case deps.setup_repo_state.(tracker) do
          :ok ->
            Resume.backfill_missing_sections(io, deps, location, tracker, config, target)
            Prewarm.maybe_resume_prewarm(io, deps, tracker, config)
            Aiur.Init.Codeowners.setup_codeowners(io, deps, tracker)
            provision(io, deps, tracker, Resume.agents_from_config(config), rate_limit_pair(config))

          {:error, reason} ->
            {:error, "Failed to create repository state: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error,
         "Couldn't read the existing config at #{target} (#{inspect(reason)}). " <>
           "Pass --force to recreate it: aiur init --force"}
    end
  end

  defp fresh_setup(io, deps, location, target) do
    tracker = Questions.prompt_tracker(io, deps, location)
    tracker = Aiur.Init.BotAccount.maybe_prompt(io, deps, tracker)

    case deps.setup_repo_state.(tracker) do
      :ok ->
        agents = Questions.prompt_agents(io)
        routing = Questions.prompt_routing(io, agents)
        permission_mode = Questions.prompt_permission_mode(io)
        workspace_root = io.input.("Where should agents work?", Questions.workspace_default(tracker), nil)
        max_agents = Questions.prompt_int(io, "Max concurrent agents", 10, 1)
        max_turns = Questions.prompt_max_turns(io)
        max_duration = Questions.prompt_max_duration(io)
        pre_warmed = Questions.prompt_int(io, "How many opencode sessions would you like to pre-warm?", 3, 0)
        # Matches Schema.Polling's default. The scaffold writes this value into
        # the generated config explicitly, so it — not the schema default — is what new
        # installs actually poll at.
        polling = Questions.prompt_int(io, "How often should aiur check the tracker for new work? (seconds)", 120, 1)
        prompt_file = if location == :global, do: "", else: io.input.("Per-repo agent prompt file", @prompt_basename, nil)
        prewarm = Prewarm.prompt_prewarm(io, deps, location)
        Prewarm.maybe_first_prewarm(io, deps, tracker, prewarm)
        alerts = Alerts.prompt_alerts(io, deps, target)
        elevenlabs = ElevenLabs.prompt_eleven_labs(io, deps, location)

        fills =
          Templates.build_fills(%{
            tracker: tracker,
            agents: agents,
            routing: routing,
            permission_mode: permission_mode,
            workspace_root: workspace_root,
            max_agents: max_agents,
            max_turns: max_turns,
            max_duration: max_duration,
            pre_warmed: pre_warmed,
            polling: polling,
            prompt_file: prompt_file,
            prewarm: prewarm,
            alerts: alerts,
            elevenlabs: elevenlabs
          })

        config_yaml = Templates.fill_template(deps.read_example.(), fills)

        case deps.write_config.(target, config_yaml) do
          {:ok, path} ->
            io.puts.(["Created: ", Format.dim(path)])
            Scaffold.ensure_prompt_file(io, deps, path, prompt_file, Map.get(tracker, :repo))
            Scaffold.ensure_aiurhooks(io, deps, path)
            Alerts.ensure_alerts(io, deps, path, alerts)
            Prewarm.ensure_prewarm_file(io, deps, path, prewarm)
            Scaffold.setup_env(io, deps, tracker)
            Scaffold.maybe_offer_gitignore(io, deps, location)
            Aiur.Init.Codeowners.setup_codeowners(io, deps, tracker)

            provision(
              io,
              deps,
              tracker
              |> Map.put(:base_branch, Aiur.Config.base_branch(tracker))
              |> Map.put(:config_path, path),
              agents
            )

          {:error, reason} ->
            {:error, "Failed to write #{Path.basename(target)}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to create repository state: #{inspect(reason)}"}
    end
  end

  defp provision(io, deps, tracker, agents, pair \\ default_rate_limit_pair())

  defp provision(io, deps, %{kind: "github"} = tracker, agents, pair) do
    with :ok <- Aiur.Init.AgentCli.check_agent_clis(io, deps, agents) do
      if github_token_present?(deps) do
        provision_github_with_token(io, deps, tracker, agents, pair)
      else
        token_setup_instructions(io)
        :ok
      end
    end
  end

  defp provision(io, deps, %{kind: "linear"} = tracker, agents, _pair) do
    with :ok <- Aiur.Init.AgentCli.check_agent_clis(io, deps, agents) do
      linear_walkthrough(io, tracker)
      final_screen(io)
      :ok
    end
  end

  defp provision(io, deps, _tracker, agents, _pair) do
    with :ok <- Aiur.Init.AgentCli.check_agent_clis(io, deps, agents) do
      final_screen(io)
      :ok
    end
  end

  defp provision_github_with_token(io, deps, tracker, agents, pair) do
    case Aiur.Init.GitHub.ensure_ci_readiness(io, deps, tracker) do
      :ok ->
        finish_github_provision(io, deps, tracker, agents, pair)

      {:error, _message} = error ->
        error
    end
  end

  defp finish_github_provision(io, deps, tracker, agents, pair) do
    case Aiur.Init.Labels.setup_labels(io, deps, tracker, agents, pair) do
      :ok -> final_screen(io)
      :error -> :ok
    end

    :ok
  end

  defp github_token_present?(deps), do: deps.github_token.() not in [nil, ""]

  defp default_rate_limit_pair, do: {Aiur.CodingAgent.default_backend(), Aiur.CodingAgent.default_rate_limit_fallback()}

  defp rate_limit_pair(config) do
    agent = Map.get(config, "agent", %{})

    case List.wrap(agent["priority"]) do
      [primary | rest] ->
        fallback = Enum.find(rest, &(&1 in Aiur.CodingAgent.rate_limit_fallback_targets()))
        {primary, fallback || Aiur.CodingAgent.default_rate_limit_fallback()}

      [] ->
        {Map.get(agent, "rate_limit_primary", Aiur.CodingAgent.default_backend()), Map.get(agent, "rate_limit_fallback", Aiur.CodingAgent.default_rate_limit_fallback())}
    end
  end

  @spec runtime_deps() :: deps()
  def runtime_deps, do: Runtime.runtime_deps()

  @doc "Raw .aiurhooks template that `aiur init` scaffolds."
  @spec aiurhooks_template() :: String.t()
  defdelegate aiurhooks_template(), to: Templates

  @doc "Raw alert sound map template that `aiur init` scaffolds as `.aiur/alerts`."
  @spec alerts_template() :: String.t()
  defdelegate alerts_template(), to: Templates

  @doc false
  @spec alerts_template({atom(), atom()} | term()) :: String.t()
  defdelegate alerts_template(os_type), to: Templates

  @doc "Raw prompt_file template (with the `{{REPO}}` placeholder) that `aiur init` scaffolds."
  @spec prompt_file_template() :: String.t()
  defdelegate prompt_file_template(), to: Templates

  @doc "Prompt_file scaffold with the repo placeholder filled for `repo` (or a neutral fallback)."
  @spec prompt_file_scaffold(String.t() | nil) :: String.t()
  defdelegate prompt_file_scaffold(repo), to: Templates

  @doc false
  @spec parse_dotenv(String.t()) :: [{String.t(), String.t()}]
  defdelegate parse_dotenv(content), to: Aiur.Init.Dotenv, as: :parse

  defp token_setup_instructions(io) do
    io.puts.("\nNext — give aiur a GitHub token so it can create labels and act as its bot account:")
    io.puts.("  1. Create a token at #{@token_url}")
    io.puts.("     Recommended — fine-grained token:")
    io.puts.("       • Repository access → `Only select repositories` → choose this repo")
    io.puts.("       • Permissions → Repository permissions:")
    io.puts.("           – Issues: Read and write  (creating labels needs this)")
    io.puts.("           – Contents: Read and write (agent branch pushes need this)")
    io.puts.("           – Pull requests: Read and write")
    io.puts.("       • Keep Administration and Actions disabled for this long-running daemon token.")
    io.puts.("     Classic fallback:")
    io.puts.("       • Click `Generate new token (classic)` and check `repo` (Full control of private repositories).")
    io.puts.("       • Classic `repo` cannot be narrowed: it also grants Administration and Actions access.")
    io.puts.("     CI enforcement is checked once during init with a separate operator-only token so admin access is not left available to agents running with bypassed permissions.")
    io.puts.("     Run `#{Aiur.GitHub.CiReadiness.operator_token_env()}=<token> aiur init` with a fine-grained token that has Contents, Actions, and Administration: Read-only.")
    io.puts.("     Never add that one-shot token to `~/.aiur/.env`, #{@env_file_name}, or the daemon environment.")
    io.puts.(IO.ANSI.format([:faint, "     The token's account must have write access to this repo (otherwise GitHub returns 404)."]))
    io.puts.("  2. Put it in #{@env_file_name} as GITHUB_TOKEN=<token> (aiur's bot account).")
    io.puts.("  3. Run `aiur init` again to continue creating repo tags.")
  end

  defp final_screen(io) do
    io.puts.("\n✅ aiur is set up. You can now:")
    io.puts.("  1. Add `agent:todo` labels to the issues you want worked.")
    io.puts.("  2. Run `aiur` (foreground) or `aiur --bg` (background) to start agents.")
  end

  defp linear_walkthrough(io, %{kind: "linear"}) do
    io.puts.("\nNext — give aiur a Linear API key:")
    io.puts.("  1. Create a personal API key at #{@linear_key_url}")
    io.puts.("  2. Set linear.api_key in your config or the LINEAR_API_KEY env var.")
    io.puts.("\n⚠️  WARNING: Linear support is LIMITED and lightly tested. If it")
    io.puts.("   breaks, please file an issue — github trackers are the happy path.")
  end

  defp linear_walkthrough(_io, _tracker), do: :ok

  @doc false
  @spec known_agent_kinds() :: [String.t()]
  defdelegate known_agent_kinds(), to: Questions
end

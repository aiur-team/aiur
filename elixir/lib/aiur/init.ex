defmodule Aiur.Init do
  @moduledoc """
  Interactive `aiur init` wizard.

  Runs as a foreground, line-based command (never the tmux-backed TUI): it
  prompts for the decisions that branch behavior, writes a pure-YAML
  `.aiurconfig` to the run folder, and — for GitHub trackers — creates the
  labels aiur depends on.

  The wizard takes an injected `io` (prompt/print) and `deps` (filesystem,
  network, auth) so it is fully unit-testable with no real side effects.
  """

  alias Aiur.CodingAgent

  @config_file_name ".aiurconfig"
  @legacy_file_name "WORKFLOW.md"
  @env_file_name ".env"
  @env_example_file_name ".env.example"
  @token_url "https://github.com/settings/tokens"

  @env_example_content """
  # aiur reads secrets from this file. Keep it out of version control.
  # GitHub personal access token (repo scope). Create one at:
  #   #{@token_url}
  GITHUB_TOKEN=
  """

  @default_label_prefix "aiur"
  @tracker_kinds ["github", "linear", "memory"]
  # Low complexity routes to the first kind, high to the last. Matches the
  # `1-2 -> claude, 3-5 -> codex` starter table the wizard teaches.
  @routing_order ["claude", "codex"]

  @type io :: %{
          puts: (IO.chardata() -> :ok),
          gets: (String.t() -> String.t() | :eof)
        }

  @type deps :: %{
          existing_config_path: (-> String.t() | nil),
          detect_repo: (-> String.t() | nil),
          write_config: (String.t() -> {:ok, Path.t()} | {:error, term()}),
          ensure_env: (String.t() -> {:created | :exists, Path.t()})
        }

  @spec run(%{force: boolean()}) :: :ok | {:error, String.t()}
  def run(opts) do
    run(opts, runtime_io(), runtime_deps())
  end

  @spec run(%{force: boolean()}, io(), deps()) :: :ok | {:error, String.t()}
  def run(opts, io, deps) do
    with :ok <- guard_existing_config(opts, deps) do
      io.puts.("Setting up aiur in this repo.")

      tracker = prompt_tracker(io, deps)
      config = assemble_config(%{tracker: tracker, agents: default_agents()})

      case deps.write_config.(to_yaml(config)) do
        {:ok, path} ->
          io.puts.("Wrote #{path}.")
          setup_env(io, deps, tracker)
          :ok

        {:error, reason} ->
          {:error, "Failed to write #{@config_file_name}: #{inspect(reason)}"}
      end
    end
  end

  defp guard_existing_config(%{force: true}, _deps), do: :ok

  defp guard_existing_config(_opts, deps) do
    case deps.existing_config_path.() do
      nil ->
        :ok

      path ->
        {:error,
         "#{Path.basename(path)} already exists at #{path}. " <>
           "Pass --force to overwrite it: aiur init --force"}
    end
  end

  defp prompt_tracker(io, deps) do
    case prompt_choice(io, "Issue tracker", @tracker_kinds, "github") do
      "github" ->
        detected = deps.detect_repo.()
        repo = prompt(io, "GitHub repo (owner/name)", detected)
        prefix = prompt(io, "Label prefix", @default_label_prefix)
        %{kind: "github", repo: repo, label_prefix: prefix}

      "linear" ->
        %{
          kind: "linear",
          api_key: prompt(io, "Linear API key", nil),
          project_slug: prompt(io, "Linear project slug", nil)
        }

      "memory" ->
        %{kind: "memory"}
    end
  end

  # GitHub is the only tracker that reads a secret from the environment
  # (the runtime resolves `GITHUB_TOKEN` for label and issue calls), so the
  # wizard scaffolds `.env` only on that path. Linear collects its key inline.
  defp setup_env(io, deps, %{kind: "github"}) do
    {status, path} = deps.ensure_env.(@env_example_content)

    case status do
      :created -> io.puts.("Created #{path} from #{@env_example_file_name}.")
      :exists -> io.puts.("Found existing #{path}; leaving it in place.")
    end

    io.puts.("Set GITHUB_TOKEN in #{path} to continue.")
    io.puts.("Create a token (repo scope) at #{@token_url}")
  end

  defp setup_env(_io, _deps, _tracker), do: :ok

  # Unprompted sections are intentionally omitted: the schema applies its
  # defaults on load, so the written file carries only the decisions the
  # wizard collected plus the starter routing table it teaches.
  defp assemble_config(%{tracker: tracker, agents: agents}) do
    %{"agent" => agent_section(agents)}
    |> put_tracker(tracker)
  end

  defp put_tracker(config, %{kind: "github", repo: repo, label_prefix: prefix}) do
    config
    |> Map.put("tracker", %{"kind" => "github"})
    |> Map.put("github", drop_nil(%{"repo" => repo, "label_prefix" => prefix}))
  end

  defp put_tracker(config, %{kind: "linear", api_key: api_key, project_slug: slug}) do
    config
    |> Map.put("tracker", %{"kind" => "linear"})
    |> Map.put("linear", drop_nil(%{"api_key" => api_key, "project_slug" => slug}))
  end

  defp put_tracker(config, %{kind: "memory"}) do
    Map.put(config, "tracker", %{"kind" => "memory"})
  end

  defp agent_section(agents) do
    %{
      "kind" => primary_kind(agents),
      "routing" => starter_routing(agents),
      "complexity_prompts" => starter_complexity_prompts()
    }
  end

  # Empty per-level placeholders so the dev can discover the knob and drop
  # in level-specific guidance that gets appended to the end of the prompt
  # for issues carrying that `complexity:<n>` label.
  defp starter_complexity_prompts do
    Map.new(1..5, &{&1, ""})
  end

  defp starter_routing(agents) do
    case agent_kinds(agents) do
      [single] ->
        Map.new(1..5, &{&1, single})

      [low, high | _] ->
        %{1 => low, 2 => low, 3 => high, 4 => high, 5 => high}
    end
  end

  defp primary_kind(agents), do: hd(agent_kinds(agents))

  defp agent_kinds(agents) do
    agents
    |> Enum.map(& &1.kind)
    |> Enum.uniq()
    |> Enum.sort_by(&Enum.find_index(@routing_order, fn k -> k == &1 end))
  end

  defp default_agents do
    [%{kind: "claude", model: nil}]
  end

  defp to_yaml(config), do: Ymlr.document!(config)

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp prompt(io, label, default) do
    suffix = if default in [nil, ""], do: "", else: " [#{default}]"

    case io.gets.("#{label}#{suffix}: ") do
      :eof ->
        default

      input ->
        case String.trim(input) do
          "" -> default
          value -> value
        end
    end
  end

  defp prompt_choice(io, label, options, default) do
    value = prompt(io, "#{label} (#{Enum.join(options, "/")})", default)

    if value in options do
      value
    else
      io.puts.("Please choose one of: #{Enum.join(options, ", ")}.")
      prompt_choice(io, label, options, default)
    end
  end

  @spec runtime_io() :: io()
  defp runtime_io do
    %{
      puts: fn message -> IO.puts(message) end,
      gets: fn prompt -> IO.gets(prompt) end
    }
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      existing_config_path: &existing_config_path/0,
      detect_repo: &detect_repo/0,
      write_config: &write_config/1,
      ensure_env: &ensure_env/1
    }
  end

  defp existing_config_path do
    cwd = File.cwd!()

    [@config_file_name, @legacy_file_name]
    |> Enum.map(&Path.join(cwd, &1))
    |> Enum.find(&File.regular?/1)
  end

  defp detect_repo do
    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} -> parse_repo(String.trim(output))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_repo(url) do
    url
    |> String.replace_suffix(".git", "")
    |> String.split(~r{[/:]}, trim: true)
    |> Enum.take(-2)
    |> case do
      [owner, name] when owner != "" and name != "" -> "#{owner}/#{name}"
      _ -> nil
    end
  end

  defp write_config(yaml) do
    path = Path.join(File.cwd!(), @config_file_name)

    case File.write(path, yaml) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_env(example_content) do
    cwd = File.cwd!()
    File.write!(Path.join(cwd, @env_example_file_name), example_content)
    env_path = Path.join(cwd, @env_file_name)

    if File.regular?(env_path) do
      {:exists, env_path}
    else
      File.write!(env_path, example_content)
      {:created, env_path}
    end
  end

  @doc false
  @spec known_agent_kinds() :: [String.t()]
  def known_agent_kinds, do: CodingAgent.known_backends()
end

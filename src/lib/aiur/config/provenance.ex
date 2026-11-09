defmodule Aiur.Config.Provenance do
  @moduledoc """
  Reports which configuration layer owns one dotted key (layers L0-L6 of the
  multi-project plan). Each layer is read separately — never through the merged
  `Aiur.Config.settings/0` — because a merged read cannot say who set what.

  There is no merge between a project file and the user file: the first existing
  of the two is the config, so L2 only counts when the project file is absent.
  L4 and L6 have no reader yet and are reported `unavailable`, never `unset`.
  """

  alias Aiur.Config.{Overrides, Schema}
  alias Aiur.Machine.Settings
  alias Aiur.Workflow

  @labels %{
    "L0" => "default",
    "L1" => "machine",
    "L2" => "user",
    "L3" => "project",
    "L4" => "shared intent",
    "L5" => "runtime",
    "L6" => "launch"
  }
  @unavailable [
    %{layer: "L4", reason: "intent_store_not_implemented"},
    %{layer: "L6", reason: "launch_flags_not_recorded"}
  ]
  @secret_segment ~r/(api_key|token|secret|password|private_key)$/
  @cap_key "agent.max_concurrent_agents"
  @redacted "<redacted>"

  @type report :: map()

  @spec labels() :: %{String.t() => String.t()}
  def labels, do: @labels

  @doc """
  Options (all injectable for tests): `:project` (`owner/repo`), `:machine_fun`,
  `:overrides_fun`, `:session_cap_fun`, `:load_fun` (path -> `{:ok, config}` |
  `:missing` | `{:error, term}`), `:candidates` (`[project_path, user_path]`),
  `:now`.
  """
  @spec explain(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def explain(key, opts \\ []) when is_binary(key) do
    path = String.split(key, ".")

    with {:ok, default} <- default(path, key),
         {:ok, machine} <- machine(opts),
         {:ok, project} <- project(machine, opts[:project]),
         {:ok, files} <- files(path, project, opts),
         {:ok, overrides} <- overrides(key, opts) do
      layers =
        [file_layers(files), runtime(key, overrides, opts)]
        |> List.flatten()
        |> Enum.sort_by(& &1.layer, :desc)

      {:ok, build(key, default, layers, cap(key, project), project, opts)}
    end
  end

  # L0: walk the schema struct; a key the struct does not have is unknown.
  defp default(path, key) do
    case walk(%Schema{}, path) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unknown_key, key, suggestions(key)}}
    end
  end

  defp walk(value, []), do: {:ok, value}
  defp walk(%{__struct__: _} = struct, [seg | rest]), do: walk_map(Map.from_struct(struct), seg, rest)
  # Free-form maps (agent.routing, ...) accept any deeper segment; their default is unset.
  defp walk(%{} = map, [seg | rest]), do: if(Map.has_key?(map, seg), do: walk(map[seg], rest), else: {:ok, nil})
  defp walk(_scalar, _rest), do: :error

  defp walk_map(map, seg, rest) do
    case Enum.find(map, fn {k, _} -> Atom.to_string(k) == seg end) do
      {_, value} -> walk(value, rest)
      nil -> :error
    end
  end

  defp suggestions(key) do
    %Schema{}
    |> flat_keys([])
    |> Enum.map(&{&1, String.jaro_distance(&1, key)})
    |> Enum.filter(fn {_, d} -> d >= 0.8 end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 0))
  end

  defp flat_keys(%{__struct__: _} = s, prefix) do
    s |> Map.from_struct() |> Enum.flat_map(fn {k, v} -> flat_keys(v, prefix ++ [Atom.to_string(k)]) end)
  end

  defp flat_keys(_leaf, prefix), do: [Enum.join(prefix, ".")]

  defp machine(opts) do
    case (opts[:machine_fun] || (&Settings.load/0)).() do
      {:ok, settings} -> {:ok, settings}
      {:error, reason} -> {:error, {:machine_unreadable, reason}}
    end
  end

  defp project(_machine, nil), do: {:ok, nil}

  defp project(machine, repo) do
    case Enum.find(machine.projects, &(String.downcase(&1.repo) == String.downcase(repo))) do
      nil -> {:error, {:unknown_project, repo, Enum.map(machine.projects, & &1.repo)}}
      entry -> {:ok, entry}
    end
  end

  defp files(path, project, opts) do
    [default_project, user] = opts[:candidates] || default_candidates()
    project_path = if project, do: Path.expand(project.config), else: default_project
    load = opts[:load_fun] || (&load_file/1)

    with {:ok, project_value} <- read_layer(load, project_path, path),
         {:ok, user_value} <- user_value(load, user, project_path, path) do
      {:ok, %{project: {project_path, project_value}, user: {user, user_value}}}
    end
  end

  defp default_candidates do
    [project_path, _legacy, user_path, _legacy_user] = Workflow.config_path_candidates()
    [project_path, user_path]
  end

  # The user file is only the config when the project file does not exist.
  defp user_value(load, user, project_path, path) do
    if load.(project_path) == :missing, do: read_layer(load, user, path), else: {:ok, :unset}
  end

  defp read_layer(load, file, path) do
    case load.(file) do
      :missing -> {:ok, :unset}
      {:ok, config} -> {:ok, fetch(config, path)}
      {:error, reason} -> {:error, {:config_unreadable, file, reason}}
    end
  end

  defp load_file(file) do
    case Workflow.load_base(file) do
      {:ok, %{config: config}} -> {:ok, config}
      {:error, {:missing_workflow_file, _, :enoent}} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(config, path) do
    case get_in(config, path) do
      nil -> :unset
      value -> {:value, value}
    end
  rescue
    _ -> :unset
  end

  defp file_layers(%{project: {pp, pv}, user: {up, uv}}) do
    [layer("L3", pp, pv), layer("L2", up, uv)]
  end

  defp layer(_id, _source, :unset), do: []
  defp layer(id, source, {:value, value}), do: [%{layer: id, source: source, value: value}]

  defp overrides(key, opts) do
    case (opts[:overrides_fun] || (&Overrides.list/0)).() do
      {:ok, entries} -> {:ok, Enum.find(entries, &(&1.key == key))}
      {:error, _} -> {:ok, nil}
    end
  end

  defp runtime(key, override, opts) do
    cond do
      override -> [%{layer: "L5", source: "runtime override (aiur set)", value: override.value}]
      key == @cap_key -> session_cap(opts)
      true -> []
    end
  end

  # `aiur set max-agents` is session-only orchestrator state, not an override entry.
  defp session_cap(opts) do
    case (opts[:session_cap_fun] || (&session_cap_default/0)).() do
      cap when is_integer(cap) -> [%{layer: "L5", source: "session cap (aiur set max-agents)", value: cap}]
      _ -> []
    end
  end

  defp session_cap_default do
    case Aiur.Orchestrator.Client.max_concurrent_agents() do
      %{configured: configured, max: max} when is_integer(max) and max != configured -> max
      _ -> nil
    end
  end

  defp cap(@cap_key, %{max_agents: cap}) when is_integer(cap), do: cap
  defp cap(_key, _project), do: nil

  defp build(key, default, layers, cap, project, opts) do
    {winner, rest} = pick(layers, default)
    {winner, rest, capped_by} = apply_cap(winner, rest, cap)
    secret? = secret?(key)
    now = opts[:now] || DateTime.utc_now()

    %{
      key: key,
      project: project && project.repo,
      value: show(winner.value, secret?),
      layer: winner.layer,
      label: @labels[winner.layer],
      source: winner.source,
      capped_by: capped_by,
      overridden: Enum.map(rest, &Map.merge(&1, %{label: @labels[&1.layer], value: show(&1.value, secret?)})),
      unavailable: @unavailable,
      observed_at: DateTime.to_iso8601(now),
      age_ms: 0,
      freshness: "live"
    }
  end

  defp pick([], default), do: {%{layer: "L0", source: "built-in default", value: default}, []}
  defp pick([winner | rest], _default), do: {winner, rest}

  defp apply_cap(winner, rest, cap) when is_integer(cap) and is_integer(winner.value) and cap < winner.value do
    {%{layer: "L1", source: "machine projects[].max_agents", value: cap}, [winner | rest], "L1"}
  end

  defp apply_cap(winner, rest, _cap), do: {winner, rest, nil}

  @doc "True when the key's last segment names a credential."
  @spec secret?(String.t()) :: boolean()
  def secret?(key), do: key |> String.split(".") |> List.last() |> then(&Regex.match?(@secret_segment, &1))

  defp show(nil, _secret?), do: nil
  defp show(_value, true), do: @redacted
  defp show(value, false), do: value
end

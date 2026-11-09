defmodule Aiur.Project.Config do
  @moduledoc """
  The one read of `projects:` in `~/.aiur/machine`: one `%Aiur.Project{}` per entry.

  A missing machine file or an empty list means no projects (the single-project
  tree). A machine file that exists but is invalid or unreadable raises
  `Aiur.Project.ConfigError` instead of falling back to the single-project tree
  and dispatching the wrong repository.
  """

  alias Aiur.Config.Paths
  alias Aiur.Machine.Settings
  alias Aiur.Project

  defmodule ConfigError do
    defexception [:message]
  end

  @spec configured() :: [Project.t()]
  def configured do
    case Settings.load() do
      {:ok, %Settings{projects: []}} -> []
      {:ok, %Settings{projects: entries}} -> build(entries)
      {:error, reason} -> raise ConfigError, message: "~/.aiur/machine is not usable: " <> describe(reason)
    end
  end

  defp build(entries) do
    projects = Enum.map(entries, &Project.from_machine_entry(&1, state_root(&1.repo)))
    check_collisions(projects)
    projects
  end

  # A sibling of today's state leaf, under the same instance-key root, named by
  # the downcased repo. The daemon's own repository resolves to today's leaf.
  defp state_root(repo) do
    case Paths.decision_state_dir() do
      {:ok, current} ->
        root = Path.dirname(current)
        leaf = Path.join(root, leaf(String.downcase(repo)))
        cased = Path.join(root, leaf(repo))

        if cased != leaf and File.dir?(cased) and not File.dir?(leaf),
          do: raise(ConfigError, message: "projects: #{repo} has state at #{cased} but the project leaf is #{leaf}; move it first")

        leaf

      {:error, reason} ->
        raise ConfigError, message: "projects: no state directory for #{repo} (#{reason})"
    end
  end

  defp leaf(repo), do: repo |> String.split("/") |> List.last() |> Paths.sanitize()

  defp check_collisions(projects) do
    for {root, [_, _ | _] = same} <- Enum.group_by(projects, & &1.state_root) do
      raise ConfigError, message: "projects: #{Enum.map_join(same, " and ", & &1.repo)} share the state directory #{root}"
    end

    :ok
  end

  defp describe({:invalid, errors}), do: Enum.map_join(errors, ", ", fn {key, message} -> "#{key} #{message}" end)
  defp describe({:unreadable, reason}), do: "unreadable (#{inspect(reason)})"
end

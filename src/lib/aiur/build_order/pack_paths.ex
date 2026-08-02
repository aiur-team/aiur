defmodule Aiur.BuildOrder.PackPaths do
  @moduledoc """
  Discovery of canonical Build Order packs on disk.

  A canonical pack lives in the repository's state node as
  `builds/<slug>/build-order.json` with a sibling daemon-owned `status.json`.
  Publisher-created discovery mirrors live in `.aiur/build_orders/*.json`, and
  `AIUR_BUILD_ORDER_DIRS` remains an explicit test/development override.

  Both the read path (`AiurWeb.BuildOrder.PlanningSource`) and the write path
  (`Aiur.BuildOrder.PackStatus`) resolve packs here so they cannot drift. The
  planning-source application overrides remain authoritative when configured.
  """

  alias Aiur.GitHub.Config
  alias Aiur.RepoBase

  @status_basename "status.json"

  @doc """
  Absolute paths of every discovered pack manifest in catalog precedence.
  """
  @spec discovered() :: [Path.t()]
  def discovered, do: discovered_sources() |> Enum.map(&elem(&1, 1))

  @doc "Discovered pack manifests tagged with their catalog source."
  @spec discovered_sources() :: [{:workspace | :state | :override, Path.t()}]
  def discovered_sources do
    (tag(workspace_packs(), :workspace) ++
       tag(state_packs(), :state) ++
       tag(override_packs(), :override))
    |> Enum.uniq_by(&elem(&1, 1))
  end

  @doc "Directories searched during normal pack discovery."
  @spec discovery_directories() :: [Path.t()]
  def discovery_directories do
    [workspace_directory(), state_directory() | override_directories()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Effective pack paths after applying planning-source overrides."
  @spec planning() :: [Path.t()]
  def planning do
    case Application.get_env(:aiur, :build_order_planning_pack) do
      nil -> Application.get_env(:aiur, :build_order_planning_packs, discovered())
      path -> [path]
    end
    |> Enum.map(&absolute/1)
  end

  @doc "Default status-poller paths, scoped to the daemon's tracked repository."
  @spec tracked_planning() :: [Path.t()]
  def tracked_planning do
    case Application.get_env(:aiur, :build_order_planning_pack) do
      path when is_binary(path) -> [absolute(path)]
      _missing -> planning() |> Enum.reject(&foreign_repository?/1)
    end
  end

  @doc "The daemon-owned status projection path beside a pack manifest."
  @spec status_path(Path.t()) :: Path.t()
  def status_path(pack_path) when is_binary(pack_path),
    do: pack_path |> Path.dirname() |> Path.join(@status_basename)

  @spec status_basename() :: String.t()
  def status_basename, do: @status_basename

  defp workspace_packs do
    workspace_directory()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == @status_basename))
  end

  defp state_packs do
    case state_directory() do
      directory when is_binary(directory) ->
        directory
        |> Path.join("*/build-order.json")
        |> Path.wildcard()

      _missing ->
        []
    end
  end

  # The override glob deliberately excludes `status.json` so the daemon's own
  # projection is never mistaken for a pack manifest.
  defp override_packs do
    override_directories()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.json")))
    |> Enum.reject(&(Path.basename(&1) == @status_basename))
  end

  defp tag(paths, source), do: Enum.map(paths, &{source, &1})

  defp workspace_directory, do: Path.join([File.cwd!(), ".aiur", "build_orders"])

  defp state_directory do
    case configured_repository() do
      repository when is_binary(repository) and repository != "" ->
        RepoBase.builds_path("https://github.com/#{repository}.git")

      _missing ->
        nil
    end
  end

  defp override_directories do
    case System.get_env("AIUR_BUILD_ORDER_DIRS") do
      dirs when is_binary(dirs) and dirs != "" -> String.split(dirs, ":", trim: true)
      _missing -> []
    end
  end

  defp configured_repository do
    Config.repo()
  rescue
    _error -> nil
  end

  defp foreign_repository?(path) do
    with repository when is_binary(repository) and repository != "" <- configured_repository(),
         {:ok, body} <- File.read(path),
         {:ok, %{"repository" => pack_repository}} when is_binary(pack_repository) <- Jason.decode(body),
         [owner, repo] when owner != "" and repo != "" <- String.split(repository, "/", parts: 2),
         [pack_owner, pack_repo] when pack_owner != "" and pack_repo != "" <- String.split(pack_repository, "/", parts: 2) do
      String.downcase(owner) != String.downcase(pack_owner) or String.downcase(repo) != String.downcase(pack_repo)
    else
      _invalid -> false
    end
  end

  defp absolute(path) do
    if Path.type(path) == :absolute, do: path, else: Application.app_dir(:aiur, path)
  end
end

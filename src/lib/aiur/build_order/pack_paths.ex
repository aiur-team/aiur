defmodule Aiur.BuildOrder.PackPaths do
  @moduledoc """
  Discovery of canonical Build Order packs on disk.

  A pack lives in the repository's state node as `builds/<slug>/build-order.json`
  with a sibling daemon-owned `status.json`. `AIUR_BUILD_ORDER_DIRS` remains an
  explicit test/development override listing directories of pack JSON files.

  Both the read path (`AiurWeb.BuildOrder.PlanningSource`) and the write path
  (`Aiur.BuildOrder.PackStatus`) resolve packs here so they cannot drift. The
  planning-source application overrides remain authoritative when configured.
  """

  alias Aiur.GitHub.Config
  alias Aiur.RepoBase

  @status_basename "status.json"

  @doc """
  Absolute paths of every discovered pack manifest, state node first.
  """
  @spec discovered() :: [Path.t()]
  def discovered, do: Enum.uniq(state_packs() ++ override_packs())

  @doc "Effective pack paths after applying planning-source overrides."
  @spec planning() :: [Path.t()]
  def planning do
    case Application.get_env(:aiur, :build_order_planning_pack) do
      nil -> Application.get_env(:aiur, :build_order_planning_packs, discovered())
      path -> [path]
    end
    |> Enum.map(&absolute/1)
  end

  @doc "The daemon-owned status projection path beside a pack manifest."
  @spec status_path(Path.t()) :: Path.t()
  def status_path(pack_path) when is_binary(pack_path),
    do: pack_path |> Path.dirname() |> Path.join(@status_basename)

  @spec status_basename() :: String.t()
  def status_basename, do: @status_basename

  defp state_packs do
    case configured_repository() do
      repository when is_binary(repository) and repository != "" ->
        repository
        |> then(&RepoBase.builds_path("https://github.com/#{&1}.git"))
        |> Path.join("*/build-order.json")
        |> Path.wildcard()

      _missing ->
        []
    end
  end

  # The override glob deliberately excludes `status.json` so the daemon's own
  # projection is never mistaken for a pack manifest.
  defp override_packs do
    case System.get_env("AIUR_BUILD_ORDER_DIRS") do
      dirs when is_binary(dirs) and dirs != "" ->
        dirs
        |> String.split(":", trim: true)
        |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.json")))
        |> Enum.reject(&(Path.basename(&1) == @status_basename))

      _missing ->
        []
    end
  end

  defp configured_repository do
    Config.repo()
  rescue
    _error -> nil
  end

  defp absolute(path) do
    if Path.type(path) == :absolute, do: path, else: Application.app_dir(:aiur, path)
  end
end

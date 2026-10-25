defmodule Aiur.IdFloorSources do
  @moduledoc "Application-owned cold-boot floor sources for the event ID counter."

  alias Aiur.Config.Paths
  alias Aiur.Executor.StatePaths
  alias Aiur.LaunchStateAdoption

  @spec floor_files() :: [Path.t()]
  def floor_files, do: [StatePaths.journal_path()]

  @spec legacy_counter_files() :: [Path.t()]
  def legacy_counter_files do
    LaunchStateAdoption.legacy_files("#{Paths.repo_name()}.event_id")
  rescue
    _ -> []
  end
end

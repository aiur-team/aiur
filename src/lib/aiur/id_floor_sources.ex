defmodule Aiur.IdFloorSources do
  @moduledoc "Application-owned cold-boot floor sources for the event ID counter."

  @spec floor_files() :: [Path.t()]
  def floor_files, do: [Aiur.Executor.StatePaths.journal_path()]

  @spec legacy_counter_files() :: [Path.t()]
  def legacy_counter_files do
    Aiur.LaunchStateAdoption.legacy_files("#{Aiur.Config.Paths.repo_name()}.event_id")
  rescue
    _ -> []
  end
end

defmodule Aiur.Config.SettingsSnapshot do
  @moduledoc "Process-local settings for one synchronous poll or status batch, scoped to one project."
  alias Aiur.Project.Context

  @key {__MODULE__, :settings}

  @spec read((-> term())) :: term()
  def read(load) do
    project = Context.current_id()

    case Process.get(@key) do
      {^project, settings} -> settings
      _ -> load.()
    end
  end

  @spec run((-> result)) :: result when result: var
  def run(fun) do
    project = Context.current_id()

    case Process.get(@key) do
      {^project, _settings} ->
        fun.()

      previous ->
        Process.put(@key, {project, Aiur.Config.settings()})

        try do
          Aiur.PathSafety.with_cached_roots(fun)
        after
          if previous, do: Process.put(@key, previous), else: Process.delete(@key)
        end
    end
  end
end

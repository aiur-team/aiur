defmodule Aiur.Project.Task do
  @moduledoc "`Task` helpers that carry the caller's project context into the task."

  alias Aiur.Project.Context

  @spec async((-> term())) :: Task.t()
  def async(fun) do
    project = Context.current()

    Task.async(fn ->
      if project, do: Context.put(project)
      fun.()
    end)
  end
end

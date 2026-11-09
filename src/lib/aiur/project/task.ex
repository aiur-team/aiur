defmodule Aiur.Project.Task do
  @moduledoc "`Task` helpers that carry the caller's project context into the task."

  alias Aiur.Project.Context

  @spec async((-> term())) :: Task.t()
  def async(fun), do: fun |> bind() |> Task.async()

  @doc "Wraps `fun` to run in the caller's project, for task starters this module does not wrap (LiveView `start_async`)."
  @spec bind((-> result)) :: (-> result) when result: var
  def bind(fun) do
    project = Context.current()

    fn ->
      if project, do: Context.put(project)
      fun.()
    end
  end
end

defmodule Mix.Tasks.Lint do
  use Mix.Task

  @moduledoc """
  Runs every independent lint check before reporting combined failures.
  """
  @shortdoc "Runs all project lint checks"

  @checks [{"specs.check", []}, {"credo", ["--strict"]}]

  @impl Mix.Task
  def run(_args) do
    run_with(&Mix.Task.run/2)
  end

  @doc false
  @spec run_with((String.t(), [String.t()] -> term())) :: :ok
  def run_with(runner) do
    failures =
      Enum.reduce(@checks, [], fn {task, args}, failures ->
        label = Enum.join([task | args], " ")
        Mix.shell().info("lint: running #{label}")

        case run_check(runner, task, args) do
          :ok ->
            failures

          {:error, reason} ->
            Mix.shell().error("lint: #{label} failed: #{reason}")
            [label | failures]
        end
      end)

    case Enum.reverse(failures) do
      [] -> :ok
      labels -> Mix.raise("lint failed: #{Enum.join(labels, ", ")}")
    end
  end

  defp run_check(runner, task, args) do
    runner.(task, args)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, {:shutdown, status} -> {:error, "exit status #{status}"}
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end
end

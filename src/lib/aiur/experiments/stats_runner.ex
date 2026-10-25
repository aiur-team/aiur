defmodule Aiur.Experiments.StatsRunner do
  @moduledoc "Serial, fail-open port to the offline statistics engine. Triggers belong to callers."
  use GenServer
  require Logger

  alias Aiur.RunTelemetry.Summaries
  alias Aiur.Workspace.WipPreservation.Command

  @type result :: :ok | {:error, :invalid_input | :timeout | :unavailable}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Recompute result.json; :timeout_ms bounds execution (default 120 seconds), excluding queue time."
  @spec recompute(Path.t(), keyword()) :: result()
  def recompute(experiment_dir, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:recompute, experiment_dir, opts}, :infinity)
  catch
    :exit, reason -> unavailable(inspect(reason))
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:recompute, dir, opts}, _from, state), do: {:reply, run(dir, opts), state}

  defp run(dir, opts) do
    with python when is_binary(python) <- System.find_executable("python3"),
         {:ok, tools} <- Summaries.reduce_dir(Keyword.get(opts, :reduce_dir)),
         script = Path.join(tools, "experiment-stats"),
         true <- File.regular?(script) do
      Command.run("nice", ["-n", "10", script, "--experiment-dir", Path.expand(dir)], timeout_ms: Keyword.get(opts, :timeout_ms, 120_000), stderr_to_stdout: true)
      |> outcome()
    else
      nil -> unavailable("python3 not found")
      _missing -> unavailable("analytics/experiment-stats not found")
    end
  rescue
    error -> unavailable(Exception.message(error))
  end

  defp outcome({:ok, {_output, 0}}), do: :ok

  defp outcome({:ok, {output, 2}}) do
    Logger.warning("experiment statistics invalid input: #{String.slice(output, 0, 2000)}")
    {:error, :invalid_input}
  end

  defp outcome({:error, {:command_timeout, _, _, _}}) do
    Logger.warning("experiment statistics timed out; tool killed")
    {:error, :timeout}
  end

  defp outcome(other), do: unavailable(inspect(other, limit: 20, printable_limit: 2000))

  defp unavailable(message) do
    Logger.warning("statistics unavailable: #{message}")
    {:error, :unavailable}
  end
end

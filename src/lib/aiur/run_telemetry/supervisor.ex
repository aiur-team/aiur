defmodule Aiur.RunTelemetry.Supervisor do
  @moduledoc false

  use Supervisor

  alias Aiur.RunTelemetry.{Sampler, UsageCapture}
  alias Aiur.RunTelemetry.Writer

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    writer_opts = Keyword.get(opts, :writer_opts, [])
    sampler_opts = Keyword.get(opts, :sampler_opts, [])
    facts_opts = Keyword.get(opts, :facts_opts, [])
    timeline_opts = Keyword.get(opts, :timeline_opts, [])
    name = Keyword.get(opts, :name, __MODULE__)
    # FactsCapture retries queued tickets with a GraphQL read on its own 5 s tick.
    facts_capture? = Application.get_env(:aiur, :run_telemetry_facts_capture?, true)

    children = [
      {Writer, writer_opts},
      if(facts_capture?, do: {Aiur.RunTelemetry.FactsCapture, facts_opts}),
      {Aiur.RunTelemetry.RepoTimeline, timeline_opts},
      {Sampler, sampler_opts},
      {UsageCapture, name: child_name(name, UsageCapture)},
      {Task.Supervisor, name: child_name(name, :UsageTasks)}
    ]

    Supervisor.init(Enum.reject(children, &is_nil/1), strategy: :one_for_one)
  end

  # The app's supervisor owns the module-named defaults; any other instance (tests) gets its own.
  defp child_name(__MODULE__, UsageCapture), do: UsageCapture
  defp child_name(__MODULE__, :UsageTasks), do: Aiur.RunTelemetry.UsageTasks
  defp child_name(name, child), do: Module.concat(name, child)
end

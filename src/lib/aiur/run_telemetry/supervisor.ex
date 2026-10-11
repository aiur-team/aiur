defmodule Aiur.RunTelemetry.Supervisor do
  @moduledoc false

  use Supervisor

  alias Aiur.RunTelemetry.Sampler
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
    Supervisor.init([{Writer, writer_opts}, {Aiur.RunTelemetry.FactsCapture, facts_opts}, {Aiur.RunTelemetry.RepoTimeline, timeline_opts}, {Sampler, sampler_opts}], strategy: :one_for_one)
  end
end

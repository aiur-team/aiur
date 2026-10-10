defmodule Aiur.TestSupport.FeatureLabelFixture do
  @moduledoc false
  alias Aiur.BuildOrder.{Features, History}
  alias Aiur.BuildOrder.Features.{LabelProjection, LabelStateStore}
  @script __MODULE__.Script
  @now ~U[2026-10-09 12:00:00Z]

  defmodule Tracker do
    @moduledoc false
    alias Aiur.TestSupport.FeatureLabelFixture, as: Fixture
    def ensure_labels(labels), do: Fixture.track({:ensure, labels})
    def add_label(n, label), do: Fixture.track({:add, n, label})
    def remove_label(n, label), do: Fixture.track({:remove, n, label})
  end

  defmodule NoEnsureTracker do
    @moduledoc false
    alias Aiur.TestSupport.FeatureLabelFixture, as: Fixture
    def add_label(n, label), do: Fixture.track({:add, n, label})
    def remove_label(n, label), do: Fixture.track({:remove, n, label})
  end

  def track(call) do
    Agent.get_and_update(@script, fn script ->
      kind = elem(call, 0)

      {reply, remaining} =
        case Map.get(script.results, kind, []) do
          [result | tail] -> {result, tail}
          [] -> {:ok, []}
        end

      send(script.observer, {:feature_label_write, call})
      {reply, %{script | calls: script.calls ++ [call], results: Map.put(script.results, kind, remaining)}}
    end)
  end

  def setup do
    dir = Aiur.TestSupport.tmp_root!("feature-labels")
    clock = ExUnit.Callbacks.start_supervised!({Agent, fn -> @now end}, id: :label_clock)
    observer = self()
    ExUnit.Callbacks.start_supervised!(%{id: :label_tracker, start: {Agent, :start_link, [fn -> %{calls: [], results: %{}, observer: observer} end, [name: @script]]}})

    f =
      ExUnit.Callbacks.start_supervised!(
        {Features, name: nil, state_dir: Path.join(dir, "registry"), general_epics: [], clock: fn -> Agent.get(clock, & &1) end, filesystem_sync_fun: fn -> :ok end, alert_fun: fn _, _, _ -> :ok end}
      )

    h = ExUnit.Callbacks.start_supervised!({History, name: __MODULE__.History, repository: "acme/widgets", state_dir: Path.join(dir, "history"), flush_ms: 60_000})
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    ctx = %{dir: dir, clock: clock, features: f, history: h, path: Path.join(dir, "projection.json")}
    create(ctx, "auth")
    create(ctx, "other")
    ctx
  end

  def start(ctx, extra \\ []) do
    opts = [
      name: nil,
      tracker: Tracker,
      clock: fn -> now(ctx) end,
      state_path: ctx.path,
      feature_options: [server: ctx.features],
      history_options: [server: ctx.history],
      label_prefix: "agent",
      tick_ms: 3_600_000
    ]

    pid = ExUnit.Callbacks.start_supervised!({LabelProjection, Keyword.merge(opts, extra)}, restart: :temporary)
    sync(pid)
    pid
  end

  def now(ctx), do: Agent.get(ctx.clock, & &1)
  def advance(ctx, seconds), do: Agent.update(ctx.clock, &DateTime.add(&1, seconds))
  def meta(ctx, source \\ "cli:test"), do: [server: ctx.features, source: source, actor: "test", at: now(ctx)]
  def create(ctx, slug), do: Features.create(slug, %{label: slug}, meta(ctx))
  def join(ctx, n, source \\ "cli:test", slug \\ "auth"), do: Features.add(slug, List.wrap(n), meta(ctx, source))
  def leave(ctx, n), do: Features.remove("auth", [n], meta(ctx))

  def observe(ctx, n, labels, extra \\ %{}) do
    fields = Map.merge(%{labels: labels, labels_complete: true}, extra)
    History.apply([%{number: n, observed_at: now(ctx), source: :poll, fields: fields}], server: ctx.history)
  end

  def sync(pid), do: LabelProjection.status(server: pid)

  def tick(pid) do
    send(pid, :tick)
    sync(pid)
  end

  def states(pid, ns), do: LabelProjection.label_states(ns, server: pid)
  def calls, do: Agent.get(@script, & &1.calls)
  def results(kind, values), do: Agent.update(@script, &put_in(&1.results[kind], values))

  def entries(ctx) do
    {:ok, entries} = LabelStateStore.load(ctx.path)
    entries
  end
end

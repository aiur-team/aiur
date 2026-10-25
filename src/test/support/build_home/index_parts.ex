defmodule Aiur.TestSupport.BuildHome.IndexParts do
  @moduledoc false
  alias Aiur.BuildOrder.History.Row
  alias Aiur.BuildOrder.{Index, Lifecycle, ProviderHealth}
  alias Aiur.Config.Schema.BuildOrder, as: BuildOrderSchema
  @now ~U[2026-10-07 14:20:00Z]

  def now, do: DateTime.to_unix(@now, :millisecond)
  def health, do: %ProviderHealth{state: :healthy, complete?: true, generation: 1, observed_at: @now}
  def source, do: %{state: "ok", observed_at: now(), reason: nil}

  def general do
    %BuildOrderSchema{} |> BuildOrderSchema.changeset(%{}) |> Ecto.Changeset.apply_changes() |> Map.fetch!(:general_epics)
  end

  def parts(rows \\ []) do
    %{
      history: {:ok, %{rows: Map.new(rows, &{&1.number, &1}), health: health()}},
      health: health(),
      catch_up: %{status: :ok, at: @now},
      features: {:ok, %{features: %{}, owners: %{}, also: %{}, health: health()}},
      overrides: {:ok, %{}, health()},
      settings: {:ok, %{build_order: %{general_epics: general()}, tracker: %{github: %{label_prefix: "agent"}}}},
      repository: {:ok, {"acme", "widgets"}},
      open: %Aiur.OpenTicketSource.Snapshot{status: :available, observed_at: @now},
      queue: %{status: :disabled},
      now: %{rows: %{}, source: source()},
      planned: %{rows: [], source: source()},
      not_queued: %{rows: [], state: :ok, reasons: [], observed_at: @now, truncated?: false}
    }
  end

  def row(number, changes \\ %{}) do
    struct!(
      %Row{
        number: number,
        title: "Ticket #{number}",
        labels: [],
        labels_complete: true,
        created_at: @now,
        lifecycle: %Lifecycle{state: :closed, state_reason: :completed},
        start: @now,
        start_source: :label,
        end: @now,
        agent_model: :unknown,
        merged_at: :none,
        blocked_by: [],
        blocked_by_complete: true
      },
      changes
    )
  end

  def now_row(number), do: %{id: to_string(number), num: number, sec: "now", status: "running", ord: number, start: now(), start_src: "dispatch", pct: 40, agent: nil}

  def plan_row(number),
    do: %{
      id: to_string(number),
      num: number,
      sec: "plan",
      status: "queued",
      ord: number,
      deps: [],
      wave: 1,
      qpos: 1,
      cue: %{held: nil, promoted: nil, wait: nil, waitAny: false, failed: nil, blockedChain: false, unknown: false}
    }

  def open(number, labels \\ []), do: %{identifier: to_string(number), title: "Open #{number}", labels: labels, created_at: @now}
  def assemble(parts), do: Index.assemble(parts, now: now())
end

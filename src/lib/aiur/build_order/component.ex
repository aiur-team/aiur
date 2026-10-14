defmodule Aiur.BuildOrder.Component do
  @moduledoc "Component-owned startup specs, split at the application’s existing child positions."

  alias Aiur.BuildOrder.{AdHocSource, EpicOverrides, Features, GraphProjection, History, PackStatus, ProgressObserver}

  @type phase :: :early | :history | :late | :view_state_sweep | :recording | :final | :label_projection

  @spec child_specs(phase(), keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def child_specs(phase, opts)

  def child_specs(:early, _opts), do: [{GraphProjection, runtime_config?: true}]

  def child_specs(:history, _opts) do
    [History, History.Feeder, {History.Backfill, enabled?: Application.get_env(:aiur, :build_history_backfill_enabled?, true)}, Features]
  end

  def child_specs(:late, _opts) do
    [
      {AdHocSource, poll_on_start: Application.get_env(:aiur, :build_order_adhoc_poll?, true)},
      {PackStatus, poll_on_start: Application.get_env(:aiur, :build_order_pack_status_poll?, true)}
    ]
  end

  def child_specs(:view_state_sweep, _opts), do: [{Aiur.GitHub.ViewStateSweep, sources: [PackStatus]}]
  def child_specs(:recording, _opts), do: [Aiur.BuildProgress, ProgressObserver]

  def child_specs(:final, _opts) do
    [EpicOverrides, {Features.RootImport, enabled?: Application.get_env(:aiur, :build_order_root_import_enabled?, true)}]
  end

  def child_specs(:label_projection, opts), do: if(Keyword.get(opts, :recording?, true), do: [Features.LabelProjection], else: [])
end

defmodule AiurWeb.AnalyticsLive.Panels do
  @moduledoc false

  import Phoenix.LiveView, only: [connected?: 1]

  alias Aiur.Usage.GroupedScopes
  alias Aiur.Usage.GroupedScopes.Scope
  alias Aiur.UsageAggregate
  alias AiurWeb.{FinancialData, FinancialDataAccess}
  alias AiurWeb.OperatorControlCenter.Analytics.{ConcurrencyCoverage, LiveConcurrency, Presenter, ScopeResolver}
  alias AiurWeb.OperatorControlCenter.UsageSummaryPresenter

  @usage_summary_max_age_ms 30_000
  # Matches the CLI: telemetry within this window is "just now", older telemetry shows elapsed age.
  @source_fresh_ms 30_000

  # The rtk panel reports a measurement rtk itself took, so every way that
  # measurement can be missing is spelled out in words. A percentage is
  # rendered only for `:ok`, and `:ok` is only reachable when rtk reported at
  # least one filtered command: with an empty history rtk answers
  # `total_commands: 0` next to `avg_savings_pct: 0.0`, and printing that "0%"
  # would state rtk saved nothing on output it never actually filtered.
  # `Aiur.Rtk.savings/1` collapses that case to `{:error, :no_data}` so the
  # distinction cannot be lost on the way to the renderer.
  #
  # Reading rtk means shelling out, so a failure here must degrade to prose
  # rather than 500 the page — the same defensive posture `kind/2` takes for
  # config reads.
  @spec rtk_panel() :: map()
  def rtk_panel do
    case Aiur.Rtk.savings(Application.get_env(:aiur, :analytics_rtk_opts, [])) do
      {:ok, savings} -> Map.put(savings, :state, :ok)
      {:error, reason} -> rtk_absent(reason)
    end
  rescue
    error -> rtk_absent({:raised, Exception.message(error)})
  catch
    :exit, reason -> rtk_absent({:exit, reason})
  end

  defp rtk_absent(:disabled) do
    rtk_state(
      "Savings reporting is off",
      "rtk savings reporting is off. Set `agent.rtk.enabled: true` to show the host-level report; this does not control a host-wide hook."
    )
  end

  defp rtk_absent(:not_installed) do
    rtk_state(
      "rtk is not installed",
      "rtk reporting is enabled but no `rtk` executable is on the daemon's PATH, so savings are unavailable."
    )
  end

  defp rtk_absent(:gh_rewrite_not_excluded) do
    rtk_state(
      "rtk gh rewrite detected",
      ~s(The host rtk hook would rewrite `gh`, reshaping calls the GitHub quota guard governs. A host-wide hook applies regardless of `agent.rtk.enabled`; configure rtk with `exclude_commands = ["gh"]` under `[hooks]`. Savings are withheld, but this report does not disable the hook.)
    )
  end

  defp rtk_absent(:no_data) do
    rtk_state(
      "No commands filtered yet",
      "rtk has recorded no commands, so there is no saving to report."
    )
  end

  defp rtk_absent(_reason) do
    rtk_state(
      "Savings could not be read",
      "rtk did not return a usable savings summary. The figure is unknown rather than zero."
    )
  end

  defp rtk_state(title, message), do: %{state: :absent, title: title, message: message}

  # The KPI strip speaks in the present tense only about a live boot. When the
  # page is showing a retained prior run (the restart fallback) or merged
  # cross-boot history, `conc_now` is the tail of a run that already ended and
  # the merged count is history, so the subtitles say "at run end" / "that run"
  # instead of claiming the fleet is acting right now.
  @spec kpi_items(map(), map(), atom(), term()) :: [map()]
  def kpi_items(model, provider_spend, source_kind, scope) do
    k = model.kpis
    present? = source_kind == :live

    [
      Map.merge(
        %{label: "Peak concurrency", tone: nil},
        ConcurrencyCoverage.tile(model, scope, "#{LiveConcurrency.label(model, present?, scope)} / #{Presenter.cap_label(model)}")
      ),
      Map.merge(%{label: "Mean utilization", tone: nil}, ConcurrencyCoverage.utilization(model, scope, "of #{model.cores} cores")),
      %{
        label: "Memory headroom",
        val: "#{k.mem_headroom_pct}%",
        sub: "#{gb(k.mem_now_bytes)} / #{gb(model.host_mem_bytes)}",
        tone: nil
      },
      %{label: "PRs merged", val: k.merged, sub: if(present?, do: "this run", else: "that run"), tone: nil},
      %{
        label: "Tickets done",
        val: "#{k.done} / #{k.total}",
        sub: "#{k.done_pct}% complete",
        tone: nil
      },
      provider_spend_item(provider_spend),
      %{
        label: "Wasted capacity",
        val: Presenter.wasted_slot_hours_label(k.wasted_slot_hours),
        sub: if(k.wasted_slot_hours_partial, do: "idle unit-slots (partial; missing cap observations)", else: "idle unit-slots"),
        tone: "block"
      }
    ]
  end

  defp provider_spend_item(%{state: :available, amount: amount, source: source}),
    do: %{label: "Provider spend", val: amount, sub: source, tone: nil}

  defp provider_spend_item(%{state: :locked}),
    do: %{label: "Provider spend", val: "Locked", sub: "financial access required", tone: nil}

  defp provider_spend_item(_other),
    do: %{label: "Provider spend", val: "—", sub: "not available", tone: nil}

  # Financial data stays behind the same per-connection capability gate used by
  # the Build Order usage summary. The analytics page receives a display-only
  # provider estimate, never aggregate cells or an unscoped raw total.
  @spec provider_spend(Phoenix.LiveView.Socket.t(), String.t() | nil) :: map()
  def provider_spend(socket, source_boot_id) do
    case {connected?(socket), authorized_context(socket)} do
      {true, {:ok, context}} -> load_provider_spend(context, socket.assigns.analytics_scope, source_boot_id)
      {_connected, :locked} -> %{state: :locked}
      {false, {:ok, _context}} -> %{state: :loading}
    end
  rescue
    _error -> %{state: :unavailable}
  catch
    _kind, _reason -> %{state: :unavailable}
  end

  defp load_provider_spend(context, analytics_scope, source_boot_id) do
    usage_aggregate = usage_aggregate_source()

    with {:ok, scope} <- ScopeResolver.usage_scope(analytics_scope, source_boot_id),
         {:ok, snapshot} <-
           FinancialData.fetch_usage_grouping(
             FinancialData,
             context,
             {Scope.public(scope), usage_aggregate_generation(usage_aggregate)},
             @usage_summary_max_age_ms,
             fn ->
               usage_aggregate.cells_snapshot() |> GroupedScopes.project(scope, currency: "USD")
             end
           ) do
      snapshot |> UsageSummaryPresenter.present() |> provider_spend_view()
    else
      _other -> %{state: :unavailable}
    end
  end

  defp provider_spend_view(%{state: state, provider_reported: %{by_currency: entries}})
       when state in [:ready, :partial, :stale] do
    case entries do
      [] ->
        %{state: :unavailable}

      _entries ->
        %{
          state: :available,
          amount: Enum.map_join(entries, ", ", &"#{&1.amount} #{&1.currency}"),
          source: "provider-reported estimate"
        }
    end
  end

  defp provider_spend_view(_view), do: %{state: :unavailable}

  @spec scope_label(term()) :: String.t()
  def scope_label(%{kind: :build_order, root_number: root_number}), do: "Build Order ##{root_number}, latest run"
  def scope_label(:session), do: "latest run"
  def scope_label(:unavailable), do: "selected Build Order unavailable"

  @spec scope_note(term(), map() | nil) :: String.t()
  def scope_note(%{kind: :build_order}, _model), do: "Only the selected Build Order's typed members in the latest run with telemetry."
  def scope_note(:session, %{tickets: [_ticket]}), do: "This is a 1-ticket window: only one ticket has telemetry in the latest run."
  def scope_note(:session, _model), do: "The latest run with telemetry. Add a Build Order selection to scope this page to its members."
  def scope_note(:unavailable, _model), do: "The selected Build Order could not provide a valid member graph."

  # The rendered charts can come from the live boot or from a retained prior
  # run (the restart fallback). The source line makes which one visible so a
  # run that ended an hour ago is never presented as the current boot, and so
  # the cutover when a fresh boot takes over is not silent.
  @spec source_kind_label(atom()) :: String.t()
  def source_kind_label(:live), do: "live boot"
  def source_kind_label(:retained), do: "retained run"
  def source_kind_label(:history), do: "retained history"

  @spec source_title(map() | nil) :: String.t()
  def source_title(%{boot_id: boot_id, observed_at: observed_at}) do
    [
      if(is_binary(boot_id), do: "boot #{boot_id}"),
      if(observed_at, do: "observed #{DateTime.to_iso8601(observed_at)}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def source_title(_source), do: ""

  @spec age_label(non_neg_integer() | nil) :: String.t()
  def age_label(nil), do: "observed at an unknown time"
  def age_label(age_ms) when age_ms <= @source_fresh_ms, do: "observed just now"
  def age_label(age_ms), do: "observed #{elapsed_seconds(div(age_ms, 1000))} ago"

  defp elapsed_seconds(seconds) when seconds < 60, do: "#{seconds}s"
  defp elapsed_seconds(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp elapsed_seconds(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
  defp elapsed_seconds(seconds), do: "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"

  @spec short_boot(String.t() | nil) :: String.t() | nil
  def short_boot(nil), do: nil
  def short_boot(id) when is_binary(id) and byte_size(id) > 8, do: binary_part(id, 0, 8)
  def short_boot(id), do: id

  @spec pressure_time(term()) :: String.t()
  def pressure_time(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  def pressure_time(_ms), do: "—"
  @spec pressure_value(term()) :: String.t()
  def pressure_value(nil), do: "—"
  def pressure_value(value), do: to_string(value)
  @spec pressure_values(map(), [atom()]) :: String.t()
  def pressure_values(sample, keys), do: Enum.map_join(keys, " / ", &pressure_value(Map.get(sample, &1)))
  @spec pressure_seconds(term()) :: String.t()
  def pressure_seconds(nil), do: "—"
  def pressure_seconds(value), do: "#{value}s"

  # The load gate holds at `load > threshold * schedulers`, so render both the
  # raw load and the scaled threshold the operator compares it against.
  @spec pressure_load(term(), term()) :: String.t()
  def pressure_load(load, threshold) when is_number(load) and is_number(threshold),
    do: "#{format_load(load)} / #{format_load(threshold)}"

  def pressure_load(load, nil) when is_number(load), do: format_load(load)
  def pressure_load(_load, _threshold), do: "—"

  defp format_load(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_load(value), do: to_string(value)

  # The live route defaults to the daemon-owned aggregate. The configurable
  # source exists only to keep the route's protected-query contract testable
  # without mutating the process-global ledger projection.
  defp usage_aggregate_source,
    do: Application.get_env(:aiur, :analytics_usage_aggregate_source, UsageAggregate)

  defp usage_aggregate_generation(usage_aggregate) do
    usage_aggregate.snapshot().generation
  rescue
    _error -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp authorized_context(socket) do
    capability = Map.get(socket.assigns, :financial_data_capability, %{})

    case {Map.get(capability, :state), FinancialDataAccess.context(socket)} do
      {:authorized, %FinancialDataAccess.Context{} = context} -> {:ok, context}
      _other -> :locked
    end
  end

  defp gb(bytes) when is_number(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  defp gb(_bytes), do: "0 GB"
end

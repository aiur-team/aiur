defmodule Aiur.Experiments.AnalystTrigger do
  @moduledoc false
  use GenServer
  require Logger
  alias Aiur.Events.Exchange
  alias Aiur.Experiments
  alias Aiur.Experiments.{Reader, ReportRecords, SampleStatus}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    :ok = Exchange.subscribe("system.experiment.*.*")
    :ok = Exchange.subscribe("experiment.*")
    state = %{enabled: Keyword.get(opts, :enabled, &enabled?/0), request: Keyword.get(opts, :request, &Experiments.analyze/2), interval: Keyword.get(opts, :interval_ms, 60_000)}
    unless opts[:start_paused?], do: send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_info({:event, event}, state) do
    if state.enabled.(), do: consume(event, state.request)
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    if state.enabled.(), do: reconcile(state.request)
    Process.send_after(self(), :reconcile, state.interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp consume(event, request) do
    event = Map.new(event, fn {key, value} -> {to_string(key), value} end)
    id = event["experiment_id"]
    kind = event["kind"] || event["line_source"]

    route(List.last(String.split(event["topic"] || "", ".")), id, kind, request)
  end

  defp route(event, id, "feature", request) when event in ~w(created preregister), do: invoke(request, id, mode: "spec", trigger: "created", requested_by: "daemon")
  defp route(event, id, _kind, request) when event in ~w(sample_guard_met report_due), do: invoke(request, id, report_opts("sample_guard_met", "interim"))
  defp route("planned_n_met", id, _kind, request), do: invoke(request, id, report_opts("planned_n_met", "confirmatory"))
  defp route("cancelled", id, _kind, _request), do: observe(cancel(id), id)
  defp route(_event, _id, _kind, _request), do: :ok

  defp reconcile(request) do
    case Experiments.list() do
      {:ok, rows} -> Enum.each(rows, &reconcile_one(&1.id, request))
      error -> observe(error, "store")
    end
  end

  defp reconcile_one(id, request) do
    case Reader.spec(id) do
      {:ok, spec, false} -> reconcile_spec(spec, request)
      {:ok, _spec, true} -> observe({:error, :store_read_only}, id)
      error -> observe(error, id)
    end
  end

  defp reconcile_spec(%{"id" => id, "status" => status}, _request) when status in ~w(cancelled abandoned), do: observe(cancel(id), id)

  defp reconcile_spec(%{"id" => id, "status" => status} = spec, request) when status in ~w(draft active report_due) do
    if get_in(spec, ["design", "change", "evidence", "source"]) == "feature", do: invoke(request, id, mode: "spec", trigger: "created", requested_by: "daemon")
    if status != "draft", do: request_reports(id, spec, request)
  end

  defp reconcile_spec(_spec, _request), do: :ok

  defp request_reports(id, spec, request) do
    with {:ok, samples} <- SampleStatus.read(spec), {:ok, records} <- ReportRecords.read(id) do
      if spec["status"] == "report_due" or minimum_met?(samples, spec), do: invoke(request, id, report_opts("sample_guard_met", "interim"))
      n = get_in(records, ["preregistration", "planned_n_per_cohort"])
      if planned_met?(samples, spec, n), do: invoke(request, id, report_opts("planned_n_met", "confirmatory"))
    else
      error -> observe(error, id)
    end
  end

  defp planned_met?(samples, spec, n), do: is_integer(n) and counts_met?(samples, spec, fn _ -> n end)

  defp minimum_met?(samples, spec), do: counts_met?(samples, spec, & &1.needed_n)

  defp counts_met?([], _spec, _threshold), do: false

  defp counts_met?(samples, spec, threshold) do
    groups = if spec["design"]["kind"] == "ab", do: Enum.map(spec["design"]["cohorts"], & &1["id"]), else: ~w(before after)
    Enum.all?(samples, fn row -> Enum.sort(Map.keys(row.counts)) == Enum.sort(groups) and Enum.all?(Map.values(row.counts), &(is_integer(&1) and &1 >= threshold.(row))) end)
  end

  defp invoke(request, id, opts), do: observe(request.(id, opts), id)
  defp observe({:error, :ticket_retry_pending}, _id), do: :ok
  defp observe({:error, reason}, id), do: Logger.warning("Experiment analyst request failed for #{id}: #{inspect(reason)}")
  defp observe(_result, _id), do: :ok

  defp cancel(id) do
    with {:ok, requests} <- Experiments.analysis_requests(id) do
      requests |> Enum.filter(&(&1["state"] == "open")) |> Enum.each(&Experiments.cancel_analysis_request(id, &1["request_id"], "experiment cancelled"))
    end
  end

  defp report_opts(trigger, type), do: [mode: "report", trigger: trigger, reason: trigger, analysis_type: type, requested_by: "daemon"]

  defp enabled? do
    Aiur.Config.telemetry_enabled?() and
      case Aiur.Config.settings() do
        {:ok, %{experiments: %{analyst: %{auto_request: enabled}}}} -> enabled
        _unconfigured -> true
      end
  end
end

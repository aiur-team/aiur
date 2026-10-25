defmodule AiurWeb.OperatorControlCenter.Analytics.Runtime do
  @moduledoc "Loads Analytics outside the HTTP request and LiveView event loop."

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Aiur.PollCadence
  alias Aiur.RunTelemetry.RetainedCache
  alias Aiur.RunTelemetry.Summaries
  alias AiurWeb.OperatorControlCenter.Analytics.{Presenter, SourceInfo}
  alias AiurWeb.OperatorControlCenter.{AwaitingCommands, DashboardShell}

  @cache_table AiurWeb.OperatorControlCenter.Analytics.Runtime.Cache

  @load_timeout_ms 15_000
  @load_tick_ms 1_000
  @persistent_model_file "latest-run-model.term"
  @persistent_model_limit 8 * 1024 * 1024

  @spec load(Phoenix.LiveView.Socket.t(), keyword(), (-> map())) :: Phoenix.LiveView.Socket.t()
  def load(socket, scope_opts, rtk_loader) do
    token = make_ref()
    started_at = System.monotonic_time(:millisecond)
    timeout_ms = Application.get_env(:aiur, :analytics_load_timeout_ms, @load_timeout_ms)
    Process.send_after(self(), {:analytics_load_tick, token}, @load_tick_ms)
    Process.send_after(self(), {:analytics_load_timeout, token}, timeout_ms)

    opts = analytics_opts(socket.assigns.range, scope_opts)

    {cached, cache_key} = cached_model(opts)

    socket =
      socket
      |> assign(
        model: cached,
        chart_model: cached,
        time_domain: nil,
        provider_spend: if(cached, do: %{state: :unavailable}, else: %{state: :loading}),
        selected: if(cached, do: MapSet.new(cached.actors, & &1.key), else: MapSet.new()),
        source: if(cached, do: SourceInfo.for_model(cached, DateTime.utc_now()), else: nil),
        unavailable: if(cached, do: nil, else: :loading),
        analytics_refreshing?: false,
        analytics_timed_out?: false,
        analytics_cache_key: cache_key,
        rtk: %{state: :absent, title: "Loading compression data", message: "Analytics loading is in progress."},
        now: DateTime.utc_now()
      )
      |> assign(analytics_load_token: token, analytics_load_started_at: started_at, analytics_load_elapsed_seconds: 0, analytics_load_timeout_seconds: timeout_ms / 1_000)

    socket = if cached, do: assign(socket, :analytics_refreshing?, true), else: socket
    start_async(socket, :analytics_model, fn -> {Presenter.load(opts), rtk_loader.()} end)
  end

  @doc false
  @spec prewarm() :: :ok
  def prewarm do
    opts = analytics_opts(:run, [])
    cache_result(cache_key(opts), Presenter.load(opts))
  end

  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:analytics_load_tick, token}, %{assigns: %{unavailable: :loading, analytics_load_token: token}} = socket) do
    elapsed = div(System.monotonic_time(:millisecond) - socket.assigns.analytics_load_started_at, 1_000)
    Process.send_after(self(), {:analytics_load_tick, token}, @load_tick_ms)
    {:noreply, assign(socket, :analytics_load_elapsed_seconds, elapsed)}
  end

  def handle_info({:analytics_load_timeout, token}, %{assigns: %{unavailable: :loading, analytics_load_token: token}} = socket) do
    {:noreply, socket |> Phoenix.LiveView.cancel_async(:analytics_model) |> assign(unavailable: :timeout, analytics_timed_out?: true)}
  end

  def handle_info({:analytics_load_timeout, token}, %{assigns: %{analytics_refreshing?: true, analytics_load_token: token}} = socket) do
    {:noreply, socket |> Phoenix.LiveView.cancel_async(:analytics_model) |> assign(:analytics_refreshing?, false) |> assign(:analytics_timed_out?, true)}
  end

  def handle_info({:analytics_load_tick, _token}, %{assigns: %{analytics_refreshing?: true}} = socket), do: {:noreply, socket}
  def handle_info({:decision_changed, _decision_id, _version}, socket), do: {:noreply, AwaitingCommands.refresh(socket)}
  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}
  def handle_info(message, socket), do: DashboardShell.handle_info(message, socket)

  @doc false
  @spec cache_result(term(), {:ok, Presenter.model()} | {:unavailable, atom()}) :: :ok
  def cache_result(_key, {:unavailable, _reason}), do: :ok

  def cache_result(key, {:ok, model}) do
    RetainedCache.put(@cache_table, key, model, max_entries: 8, max_value_bytes: @persistent_model_limit)
    persist_model(key, model)
  end

  defp cached_model(opts) do
    key = cache_key(opts)

    cached = RetainedCache.lookup(@cache_table, key) || load_persisted_model(key)
    if cached, do: RetainedCache.put(@cache_table, key, cached, max_value_bytes: @persistent_model_limit)
    {cached, key}
  end

  # The state node scopes the in-memory model to the analytics root its persisted copy lives under.
  defp cache_key(opts) do
    {Keyword.get(opts, :session, :current), Keyword.get(opts, :build_order), Keyword.get(opts, :tickets), Keyword.get(opts, :cache_identity), Summaries.state_node()}
  end

  defp analytics_opts(range, scope_opts) do
    [
      range: range,
      session: if(range == :full, do: :cross, else: :current),
      telemetry_file: Application.get_env(:aiur, :analytics_telemetry_file),
      orchestrator: AiurWeb.EndpointConfig.get(:orchestrator) || Aiur.Orchestrator,
      snapshot_timeout_ms: PollCadence.snapshot_tolerance_ms(AiurWeb.EndpointConfig.get(:snapshot_timeout_ms) || 15_000)
    ] ++ scope_opts
  end

  defp persist_model({:current, nil, nil, nil, state_node}, model) do
    path = Path.join([state_node, "analytics", @persistent_model_file])
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
    binary = :erlang.term_to_binary(model, [:compressed])

    if byte_size(binary) <= @persistent_model_limit do
      write_model(path, temporary, binary)
    end

    :ok
  rescue
    _error -> :ok
  end

  defp persist_model(_key, _model), do: :ok

  defp write_model(path, temporary, binary) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(temporary, binary, [:binary, :exclusive])
    File.rename!(temporary, path)
    File.chmod(path, 0o600)
  after
    File.rm(temporary)
  end

  defp load_persisted_model({:current, nil, nil, nil, state_node}) do
    path = Path.join([state_node, "analytics", @persistent_model_file])

    with {:ok, stat} when stat.size <= @persistent_model_limit <- File.stat(path),
         {:ok, binary} <- File.read(path) do
      decoded_model = :erlang.binary_to_term(binary, [:safe])

      case decoded_model do
        %{actors: actors, source_observed_at: observed_at, source_boot_id: boot_id}
        when is_list(actors) and (is_binary(observed_at) or is_nil(observed_at)) and
               (is_binary(boot_id) or is_nil(boot_id)) ->
          decoded_model

        _invalid ->
          nil
      end
    else
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp load_persisted_model(_key), do: nil
end

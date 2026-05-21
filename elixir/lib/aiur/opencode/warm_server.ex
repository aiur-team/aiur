defmodule Aiur.Opencode.WarmServer do
  @moduledoc """
  Owns the pre-warmed `opencode serve` Aiur spawns at boot in a neutral
  workspace. Eating the ~3-4 s serve startup off the user's critical
  path is half the perceived-latency win for first agent open; the
  attach-side warm-up lives in `Aiur.Opencode.WarmAttach`.

  After the serve is ready, runs boot-time GC against opencode's session
  list: any session whose model is Aiur-owned but whose title doesn't
  match an active agent identifier was left behind by an ungraceful
  prior exit and is deleted. This is the recovery story for crash paths
  that bypass the shutdown chokepoint (`kill -9`, BEAM panic, OOM).
  """

  use GenServer
  require Logger

  alias Aiur.Opencode.{ApiClient, Config, Protocol, Server, WorkspaceSetup}

  defstruct [
    :workspace,
    :base_url,
    :server,
    :token,
    :ready_waiters,
    :ready?
  ]

  @placeholder_title "_placeholder"
  @ready_topic "opencode:warm"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec base_url() :: String.t() | nil
  def base_url do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :base_url, 100)
    else
      nil
    end
  catch
    :exit, _ -> nil
  end

  @spec await_ready(timeout()) :: {:ok, String.t()} | :timeout | :disabled
  def await_ready(timeout \\ 15_000) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, :await_ready, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
      end
    else
      :disabled
    end
  end

  @impl true
  def init(_opts) do
    if Config.prewarm_disabled?() do
      :ignore
    else
      {:ok, %__MODULE__{ready_waiters: [], ready?: false}, {:continue, :boot}}
    end
  end

  @impl true
  def handle_continue(:boot, state) do
    workspace = Config.prewarm_workspace()
    _ = File.mkdir_p(workspace)
    bridge_url = "http://#{Config.bridge_host()}:#{Config.bridge_port()}"

    with {:ok, token} <- WorkspaceSetup.materialize_prewarm(workspace, bridge_url),
         {:ok, server} <- Server.start_link(%{identifier: "_warm", workspace: workspace}),
         {:ok, base_url, _os_pid} <- Server.await_ready(server) do
      Logger.info(
        "opencode_warm_server phase=ready elapsed_ms=#{Aiur.Boot.elapsed_ms()} base_url=#{base_url}"
      )

      gc_leftover_sessions(base_url)

      Enum.each(state.ready_waiters, &GenServer.reply(&1, {:ok, base_url}))
      Phoenix.PubSub.broadcast(Aiur.PubSub, @ready_topic, {:warm_server_ready, base_url})

      {:noreply,
       %{
         state
         | workspace: workspace,
           base_url: base_url,
           server: server,
           token: token,
           ready_waiters: [],
           ready?: true
       }}
    else
      reason ->
        Logger.warning("opencode_warm_server boot_failed reason=#{inspect(reason)}")
        Enum.each(state.ready_waiters, &GenServer.reply(&1, :error))
        {:stop, {:shutdown, reason}, state}
    end
  end

  @impl true
  def handle_call(:base_url, _from, state), do: {:reply, state.base_url, state}

  def handle_call(:await_ready, _from, %{ready?: true, base_url: url} = state),
    do: {:reply, {:ok, url}, state}

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.server) and Process.alive?(state.server) do
      _ = GenServer.stop(state.server, :normal, 1_000)
    end

    :ok
  end

  # --- boot-time GC -------------------------------------------------------

  defp gc_leftover_sessions(base_url) do
    active = MapSet.new(Aiur.Orchestrator.list_active_identifiers())

    case ApiClient.list_sessions(base_url) do
      {:ok, sessions} ->
        deleted =
          sessions
          |> Enum.filter(&aiur_orphan?(&1, active))
          |> Enum.map(fn session ->
            id = session["id"] || session[:id]
            _ = ApiClient.delete_session(base_url, id)
            id
          end)
          |> Enum.count()

        kept = length(sessions) - deleted
        Logger.info("opencode_warm_server gc_complete kept=#{kept} deleted=#{deleted}")

      {:error, reason} ->
        Logger.warning("opencode_warm_server gc_skipped reason=#{inspect(reason)}")
    end
  end

  defp aiur_orphan?(session, active_set) do
    title = session["title"] || session[:title] || ""
    model = parse_model_field(session["model"] || session[:model])

    title != @placeholder_title and
      Protocol.aiur_owned?(model) and
      not MapSet.member?(active_set, title)
  end

  defp parse_model_field(model) when is_map(model), do: model

  defp parse_model_field(model) when is_binary(model) do
    case Jason.decode(model) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp parse_model_field(_), do: %{}
end

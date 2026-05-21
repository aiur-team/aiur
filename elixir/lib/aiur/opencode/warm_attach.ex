defmodule Aiur.Opencode.WarmAttach do
  @moduledoc """
  Pre-launches one `opencode attach` in a hidden tmux window at aiur
  boot and exposes `take_over/3` for the first agent open.

  Once `WarmServer` publishes `{:warm_server_ready, base_url}` on
  `Aiur.PubSub` topic `"opencode:warm"`, this module:

  1. Creates a placeholder opencode session via the API with
     `model: %{providerID: "aiur", id: "placeholder"}` so any stray
     chat-completion call against it is short-circuited by
     `Aiur.Opencode.ChatCompletions` (see `identifier_from_model/1`).
  2. Spawns `opencode attach <warm_url> --session <placeholder>` inside
     a hidden tmux window via `Aiur.Tmux.new_hidden_window/3`.

  When PaneManager calls `take_over/3` on the first agent open, the
  hidden pane is `select-session`-switched to the agent's session and
  `join-pane`d into the visible PaneManager-owned window. v1 is
  single-shot: after one `take_over/3`, state moves to `:handed_off`
  and subsequent calls return `{:error, :not_ready}` so PaneManager
  falls back to cold attach.
  """

  use GenServer
  require Logger

  alias Aiur.Opencode.{ApiClient, Config, Protocol}
  alias Aiur.Tmux

  defstruct [
    :status,
    :base_url,
    :placeholder_session_id,
    :hidden_pane_id,
    :hidden_window_name
  ]

  @ready_topic "opencode:warm"
  @hidden_window_name "aiur-warm-attach"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec status() :: :booting | :waiting | :ready_with_placeholder | :handed_off | :disabled
  def status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :status, 200)
    else
      :disabled
    end
  catch
    :exit, _ -> :disabled
  end

  @doc """
  Hand the warm pane off to `identifier`. Switches the attached TUI to
  `session_id` via opencode's `/tui/select-session`, then `join-pane`s
  the hidden pane into `target_window`. One-shot in v1.
  """
  @spec take_over(String.t(), String.t(), String.t()) ::
          {:ok, %{pane_id: String.t()}} | {:error, term()}
  def take_over(identifier, session_id, target_window)
      when is_binary(identifier) and is_binary(session_id) and is_binary(target_window) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:take_over, identifier, session_id, target_window}, 15_000)
    else
      {:error, :not_ready}
    end
  catch
    :exit, _ -> {:error, :not_ready}
  end

  @impl true
  def init(_opts) do
    if Config.prewarm_disabled?() do
      :ignore
    else
      :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, @ready_topic)
      {:ok, %__MODULE__{status: :waiting, hidden_window_name: @hidden_window_name}}
    end
  end

  @impl true
  def handle_info({:warm_server_ready, base_url}, %{status: :waiting} = state) do
    {:noreply, %{state | base_url: base_url, status: :booting}, {:continue, :boot}}
  end

  def handle_info({:warm_server_ready, _base_url}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_continue(:boot, state) do
    with {:ok, session_id} <- create_placeholder_session(state.base_url),
         attach_cmd = Protocol.attach_command(state.base_url, session_id),
         {:ok, pane_id} <- Tmux.new_hidden_window(state.hidden_window_name, attach_cmd) do
      Logger.info(
        "opencode_warm_attach phase=ready pane_id=#{pane_id} session_id=#{session_id} base_url=#{state.base_url}"
      )

      {:noreply,
       %{state | status: :ready_with_placeholder, placeholder_session_id: session_id, hidden_pane_id: pane_id}}
    else
      reason ->
        Logger.warning("opencode_warm_attach boot_failed reason=#{inspect(reason)}")
        {:noreply, %{state | status: :booting}}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(
        {:take_over, _identifier, _session_id, _target_window},
        _from,
        %{status: status} = state
      )
      when status != :ready_with_placeholder do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:take_over, identifier, session_id, target_window}, _from, state) do
    with :ok <- ApiClient.select_session(state.base_url, session_id),
         :ok <- Tmux.join_pane(state.hidden_pane_id, target_window) do
      Logger.info(
        "opencode_warm_attach handed_off identifier=#{identifier} session_id=#{session_id} pane_id=#{state.hidden_pane_id}"
      )

      {:reply, {:ok, %{pane_id: state.hidden_pane_id}}, %{state | status: :handed_off}}
    else
      {:error, reason} = err ->
        Logger.warning("opencode_warm_attach take_over_failed reason=#{inspect(reason)}")
        {:reply, err, state}
    end
  end

  # --- internals ----------------------------------------------------------

  defp create_placeholder_session(base_url) do
    opts = [model: %{providerID: "aiur", id: "placeholder"}]

    case ApiClient.create_session(base_url, "_placeholder", opts) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, %{id: id}} when is_binary(id) -> {:ok, id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      error -> error
    end
  end
end

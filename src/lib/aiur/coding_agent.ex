defmodule Aiur.CodingAgent do
  @moduledoc """
  Adapter boundary for coding agent backends.

  Backend identity lives in a single registry (`backends/0`). Module
  dispatch, delivery-policy defaults, and config validation all derive
  from it, so adding a backend is one registry entry rather than edits
  across every `case` statement. Unknown backends fail loud.

  Per-issue routing is resolved by `backend_for/1` (a `model:<backend>`
  override label, then the `agent.routing` complexity table, then the
  global `agent.kind` fallback) and is fixed for an issue once its
  session starts.
  """

  alias Aiur.CodingAgent.ModelGrammar
  alias Aiur.CodingAgent.ProvidersView
  alias Aiur.CodingAgent.Routing
  alias Aiur.Config

  @type backend :: String.t()
  @type provider_descriptor :: ProvidersView.provider_descriptor()

  @type operator_payload :: %{required(:kind) => :text, required(:body) => String.t()}
  @type safe_checkpoint :: %{required(:kind) => atom(), optional(:method) => String.t()}

  @type checkpoint_callback_result ::
          :noop
          | {:deliver_text, String.t(), (map() -> any()), (term() -> any())}

  # Registry views and provider descriptors.
  defdelegate backends(), to: ProvidersView
  defdelegate known_backends(), to: ProvidersView
  defdelegate model_required?(backend), to: ProvidersView
  defdelegate dispatchable_backends(backend_configs \\ %{}), to: ProvidersView
  defdelegate rate_limit_fallback_targets(), to: ProvidersView
  defdelegate default_backend(), to: ProvidersView
  defdelegate default_config_backend(), to: ProvidersView
  defdelegate default_rate_limit_fallback(), to: ProvidersView
  defdelegate skill_install_locations(), to: ProvidersView
  defdelegate configurable_backends(), to: ProvidersView
  defdelegate family_for(backend), to: ProvidersView
  defdelegate provider_descriptors(), to: ProvidersView
  defdelegate provider_families(), to: ProvidersView
  defdelegate provider_family_map(), to: ProvidersView
  defdelegate usage_context(backend), to: ProvidersView
  defdelegate usage_backends(), to: ProvidersView
  defdelegate usage_transports(), to: ProvidersView
  defdelegate provider_descriptor(provider), to: ProvidersView
  defdelegate provider_pricing(provider), to: ProvidersView
  defdelegate provider_account_generation(provider), to: ProvidersView
  defdelegate provider_meter_backend(provider), to: ProvidersView
  defdelegate provider_meter_probe(provider), to: ProvidersView

  # Model and label grammar.
  defdelegate efforts(backend), to: ModelGrammar
  defdelegate override_labels(), to: ModelGrammar
  defdelegate override_labels(selected), to: ModelGrammar
  defdelegate override_labels(selected, ids_for), to: ModelGrammar
  defdelegate alias_labels(), to: ModelGrammar
  defdelegate override_effort_labels(), to: ModelGrammar
  defdelegate models(backend), to: ModelGrammar
  defdelegate model_aliases(backend), to: ModelGrammar
  defdelegate seedable_models(backend), to: ModelGrammar
  defdelegate resolve_model(backend, model, opts \\ []), to: ModelGrammar
  defdelegate known_model?(backend, model), to: ModelGrammar

  # Per-issue selection and routing.
  defdelegate backend_for(issue, opts \\ []), to: Routing
  defdelegate select_for_dispatch(issue, opts \\ []), to: Routing
  defdelegate peak_priced_route?(route, now), to: Routing
  defdelegate route_price_identity(route), to: Routing
  defdelegate model_for(issue, opts \\ []), to: Routing
  defdelegate effort_for(issue), to: Routing
  defdelegate override_backend(issue, opts \\ []), to: Routing
  defdelegate model_label_status(issue, opts \\ []), to: Routing
  defdelegate routing_backend(issue), to: Routing
  defdelegate routing_model(issue), to: Routing
  defdelegate routing_remote?(issue), to: Routing
  defdelegate complexity_level(issue), to: Routing
  defdelegate remote_control_forced?(issue), to: Routing

  @spec adapter() :: module()
  def adapter, do: adapter(Config.agent_kind())

  @doc "Adapter module for a resolved backend. Raises on an unknown backend."
  @spec adapter(backend()) :: module()
  def adapter(backend), do: fetch_backend!(backend).adapter

  @doc """
  Backend-specific module that knows how to turn a raw notification
  message into a transcript event (or skip it). Keeps the codex / Claude
  notification-shape differences out of `Aiur.AgentRunner`. Each module
  exposes `extract(message, fallback_turn_id) :: {:ok, transcript_event} | :skip`.
  """
  @spec transcript_module() :: module()
  def transcript_module, do: transcript_module(Config.agent_kind())

  @doc "Transcript module for a resolved backend. Raises on an unknown backend."
  @spec transcript_module(backend()) :: module()
  def transcript_module(backend), do: fetch_backend!(backend).transcript

  @doc "Delivery-policy default: whether the backend supports Executor interrupts."
  @spec can_interrupt?(backend()) :: boolean()
  def can_interrupt?(backend), do: fetch_backend!(backend).can_interrupt

  @doc "Whether the provider can safely replace its session after this error."
  @spec recoverable_session_error?(backend(), term()) :: boolean()
  def recoverable_session_error?(backend, reason) do
    case Map.fetch(backends(), backend) do
      {:ok, %{recoverable_session_error: classifier}} -> classifier.(reason)
      _ -> false
    end
  end

  @doc "Whether the backend can emit correlated worker-application evidence for unit controls."
  @spec control_application_confirmation(backend()) :: :confirmed | :request_only | :unsupported
  def control_application_confirmation(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :control_application_confirmation, :request_only)
      :error -> :unsupported
    end
  end

  @doc "Delivery-policy default: which checkpoint kinds are safe to deliver on."
  @spec safe_checkpoints(backend()) :: [atom()]
  def safe_checkpoints(backend), do: fetch_backend!(backend).safe_checkpoints

  @doc """
  Whether the backend can hand an agent off to a `claude remote-control`
  session. Unknown backends are not RC-capable.
  """
  @spec remote_control?(backend()) :: boolean()
  def remote_control?(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :remote_control, false)
      :error -> false
    end
  end

  @doc "Whether the backend can execute its session and tools on an SSH worker."
  @spec remote_worker?(backend()) :: boolean()
  def remote_worker?(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :remote_worker, true)
      :error -> false
    end
  end

  @doc """
  Whether a backend can resume a prior agent thread across an aiur restart
  (reattach to the same session rather than cold-start a new conversation).
  Wired today for codex (app-server `thread/resume` against its on-disk
  rollout) and `claude-repl` (the REPL `--resume`s the on-disk transcript
  jsonl). The headless `claude` backend's external app-server keeps an
  in-memory-only thread map and exposes no disk-resume seed, so it — and any
  unknown backend — is not resumable and degrades to a clean start.
  """
  @spec resumable?(backend()) :: boolean()
  def resumable?(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :resumable, false)
      :error -> false
    end
  end

  @doc """
  The transport backend an RC-promoted session actually runs on.
  `"claude"` declares the REPL backend as its remote transport; a backend
  with no declared transport — and any unknown backend — promotes
  to itself (no swap).
  """
  @spec remote_transport(backend()) :: backend()
  def remote_transport(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :remote_transport, backend)
      :error -> backend
    end
  end

  @doc """
  The backend a failed spawn falls back to, or `nil` when the
  backend declares no fallback. `"claude-repl"` falls back to the
  headless claude backend. Unknown backends have no fallback.
  """
  @spec fallback_backend(backend()) :: backend() | nil
  def fallback_backend(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :fallback_backend, nil)
      :error -> nil
    end
  end

  @doc """
  Whether a remote-control session on this backend feeds the pane
  display tailer. True only for the hook-driven RC REPL, whose hook
  path alone paints a sparse skeleton; every other backend streams its
  own rich transcript and must not get a second display source.
  """
  @spec rc_display_tail?(backend()) :: boolean()
  def rc_display_tail?(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :rc_display_tail, false)
      :error -> false
    end
  end

  @doc """
  How a live session's OS-level runtime is reported to the orchestrator
  for brutal-kill teardown: `:repl_pane` (pane_id / os_pid /
  session_url), `:headless_wrapper` (the non-exec bash wrapper pid to
  tree-reap), or nil (the backend's ProcessReaper registration already
  covers it).
  """
  @spec runtime_report(backend()) :: :repl_pane | :headless_wrapper | nil
  def runtime_report(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :runtime_report)
      :error -> nil
    end
  end

  @doc """
  The canonical Executor-facing label that forces remote control on for an
  issue (`model:remote`). Added/removed by the AgentList `r` key to
  promote/demote a running agent; it is the durable source of truth for
  remote-ness across re-dispatches.
  """
  @spec remote_control_alias_label() :: String.t()
  def remote_control_alias_label, do: "model:remote"

  @doc """
  Whether the backend takes Executor messages immediately (pass-through to
  the live process) instead of holding them at a `:checkpoint`. True only
  for the persistent-REPL backend, whose native input queue accepts a
  message mid-turn. Unknown backends are not immediate-delivery.
  """
  @spec immediate_delivery?(backend()) :: boolean()
  def immediate_delivery?(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :immediate_delivery, false)
      :error -> false
    end
  end

  @spec start_session(Path.t()) :: {:ok, map()} | {:error, term()}
  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    backend = Keyword.get(opts, :backend) || Config.agent_kind()
    adapter(backend).start_session(workspace, opts)
  end

  @spec run_turn(map(), String.t(), map()) :: {:ok, map()} | {:paused, map()} | {:error, term()}
  @spec run_turn(map(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:paused, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []),
    do: adapter_for_session(session).run_turn(session, prompt, issue, opts)

  @spec stop_session(map()) :: :ok | {:ok, :cleanup_proven} | {:error, term()}
  def stop_session(session), do: adapter_for_session(session).stop_session(session)

  @spec normalize_event(map()) :: map()
  def normalize_event(event), do: normalize_event(event, Config.agent_kind())

  @spec normalize_event(map(), backend()) :: map()
  def normalize_event(event, backend), do: adapter(backend).normalize_event(event)

  @spec send_operator_message(map(), operator_payload()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(session, payload),
    do: adapter_for_session(session).send_operator_message(session, payload)

  defp adapter_for_session(%{backend: backend}) when is_binary(backend), do: adapter(backend)

  defp adapter_for_session(session) do
    raise ArgumentError,
          "cannot resolve coding-agent backend for session #{inspect(session)}; expected a binary :backend"
  end

  defp fetch_backend!(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} ->
        entry

      :error ->
        raise ArgumentError,
              "unknown coding-agent backend #{inspect(backend)}; known backends: #{inspect(known_backends())}"
    end
  end
end

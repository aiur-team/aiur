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

  alias Aiur.Config
  alias Aiur.Config.RoutingValue
  alias Aiur.Issue

  @type backend :: String.t()

  @type operator_payload :: %{required(:kind) => :text, required(:body) => String.t()}
  @type safe_checkpoint :: %{required(:kind) => atom(), optional(:method) => String.t()}

  @type checkpoint_callback_result ::
          :noop
          | {:deliver_text, String.t(), (map() -> any()), (term() -> any())}

  @complexity_label ~r/^complexity:(\d+)$/
  # `model:<backend>` selects a backend with its configured default model.
  # `model:<backend>-<variant>` additionally pins a model string passed to
  # that backend (e.g. `model:claude-opus-4-8`). The whole spec charset is
  # restricted to word/dot/dash so it is safe to splice into a backend's
  # spawned command without shell-injection risk. The backend/variant
  # boundary is resolved against the known-backend list (see
  # `resolve_backend_spec/2`), so a hyphenated backend like `claude-repl`
  # is recognized rather than mis-split into `claude` + variant `repl`.
  @model_override_label ~r/^model:([A-Za-z0-9.\-]+)$/

  # Remote-control flag aliases. `model:remote` is a pure flag: it forces
  # remote-control ON for the issue (see `remote_control_forced?/1`) but never
  # selects a backend — the model comes from a companion `model:<backend>` tag
  # and dispatch swaps the transport to the mapped value (`claude-repl`, the
  # remote transport the flag implies).
  @backend_aliases %{"remote" => "claude-repl"}

  @doc """
  Registry of supported coding-agent backends. Each entry carries the
  modules, delivery-policy defaults, the model variants worth seeding as
  `model:<backend>-<variant>` override labels, and the backend's valid
  reasoning-`efforts` (used by per-complexity routing). Adding a backend
  means adding one entry here.

  Effort sets are backend-native and verified against the installed CLIs:
  codex maps to `model_reasoning_effort`; the interactive Claude REPL maps
  to `claude --effort`. The headless `claude` backend runs through
  `aiur-claude`, whose current app-server wrapper does not expose an effort
  option, so it intentionally has no effort vocabulary.
  """
  @spec backends() :: %{backend() => Aiur.CodingAgent.Backend.capabilities()}
  def backends do
    %{
      "codex" => %{
        adapter: Aiur.Codex.CodingAgent,
        transcript: Aiur.Codex.Transcript,
        can_interrupt: true,
        safe_checkpoints: [:notification, :tool_result],
        remote_control: false,
        # The codex app-server can rejoin a prior thread across an aiur restart
        # via `thread/resume` against its on-disk rollout, so a respawned
        # session continues rather than cold-starting (issue #378).
        resumable: true,
        models: ["gpt-5.5", "gpt-5.4", "gpt-5.5-mini", "gpt-5.4-mini"],
        efforts: ["low", "medium", "high"]
      },
      "claude" => %{
        adapter: Aiur.Claude.CodingAgent,
        transcript: Aiur.Claude.Transcript,
        can_interrupt: true,
        safe_checkpoints: [:notification],
        remote_control: true,
        # Remote control physically runs on the persistent-REPL transport,
        # so an RC-promoted claude issue dispatches claude-repl (carrying
        # the resolved model). Declared here so dispatch code never
        # hard-codes the swap.
        remote_transport: "claude-repl",
        # The headless `bash -lc` wrapper does not exec; report its os pid so
        # brutal-kill teardown can tree-reap the reparented claude/node children.
        runtime_report: :headless_wrapper,
        # Headless claude runs through the external `aiur-claude` app-server,
        # whose thread map is in-memory only (lost on restart) and whose
        # `thread/start` exposes no way to seed a prior session id. aiur can't
        # inject a disk `--resume` without an app-server protocol change, so the
        # headless backend stays a clean start. Resume on the REPL transport
        # (`claude-repl`), which drives the `claude` CLI directly, instead.
        resumable: false,
        models: ["opus", "sonnet", "haiku", "opus-4-8", "sonnet-4-6", "haiku-4-5"],
        efforts: []
      },
      "claude-repl" => %{
        adapter: Aiur.Claude.ReplAgent,
        transcript: Aiur.Claude.Transcript,
        # Operator messages are typed straight into the live pane and the
        # agent's native input queue folds them in, so there is no
        # checkpoint to hold at — `safe_checkpoints` stays empty and
        # delivery is immediate. Interrupt is the explicit out-of-band
        # action: `ReplAgent.interrupt/1` sends Ctrl+C to the pane, cutting
        # the active turn so a queued message drains right away.
        can_interrupt: true,
        safe_checkpoints: [],
        immediate_delivery: true,
        remote_control: true,
        # A tmux/RC start failure must never strand an issue: a failed
        # claude-repl spawn falls back once to the headless claude
        # backend. Declared here so the fallback never lives in a
        # dispatch `case`.
        fallback_backend: "claude",
        # Only the hook-driven RC REPL needs the pane display tailer; every
        # other backend streams its own rich transcript.
        rc_display_tail: true,
        # The persistent pane + REPL os pid are what an abort path must reap.
        runtime_report: :repl_pane,
        # The REPL spawns the `claude` CLI directly, so a respawn after an aiur
        # restart can `--resume <session-id>` against the on-disk transcript
        # jsonl (the session id is the transcript filename). The runner injects
        # the persisted handle's id and `ReplAgent` degrades to a clean start
        # when that transcript is gone (issue #613, follow-up to #378).
        resumable: true,
        models: ["opus", "sonnet", "haiku", "opus-4-8", "sonnet-4-6", "haiku-4-5"],
        efforts: ["low", "medium", "high", "xhigh", "max"]
      }
    }
  end

  @doc "Known backend keys, derived from the registry."
  @spec known_backends() :: [backend()]
  def known_backends, do: Map.keys(backends())

  @doc """
  The valid reasoning-effort values for a backend, derived from the
  registry. Unknown backends have no efforts. Used by per-complexity
  routing validation (`Aiur.Config.Schema.AgentValidation.validate_agent_routing/2`) and
  the `aiur init` wizard to offer backend-appropriate options.
  """
  @spec efforts(backend()) :: [String.t()]
  def efforts(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :efforts, [])
      :error -> []
    end
  end

  @doc """
  Canonical `model:*` override labels worth auto-creating in a repo: a
  bare `model:<backend>` per known backend plus a
  `model:<backend>-<variant>` for each registry-listed model variant.
  Derived from the registry so new backends/models seed automatically.
  """
  @spec override_labels() :: [String.t()]
  def override_labels, do: override_labels(known_backends()) ++ alias_labels()

  @doc "Label-only alias override labels (e.g. `model:remote`)."
  @spec alias_labels() :: [String.t()]
  def alias_labels, do: Enum.map(Map.keys(@backend_aliases), &"model:#{&1}")

  @doc """
  `override_labels/0` restricted to the given backends. Each backend
  contributes only its own `model:<backend>[-<variant>]` labels, so a
  hyphenated backend (`claude-repl`) is never seeded by selecting a
  shorter-named one (`claude`).
  """
  @spec override_labels([backend()]) :: [String.t()]
  def override_labels(selected) do
    backends()
    |> Map.take(selected)
    |> Enum.flat_map(fn {backend, entry} ->
      variant_labels = Enum.map(Map.get(entry, :models, []), &"model:#{backend}-#{&1}")
      ["model:#{backend}" | variant_labels]
    end)
  end

  @doc """
  Resolve the backend for an issue: a `model:<backend>` override label
  wins, then the `complexity:` label mapped through `agent.routing`,
  then the global `agent.kind` fallback.
  """
  @spec backend_for(Issue.t()) :: backend()
  def backend_for(%Issue{} = issue) do
    override_backend(issue) || routing_backend(issue) || Config.agent_kind()
  end

  @doc """
  Pinned model string for an issue from a `model:<backend>-<variant>`
  override label (e.g. `model:claude-opus-4-8` -> `"opus-4-8"`), or `nil`
  when no variant is pinned. The bare `model:<backend>` form selects the
  backend but pins no model, so the backend's configured default applies.
  """
  @spec model_for(Issue.t()) :: String.t() | nil
  def model_for(%Issue{} = issue) do
    override_model(issue) || routing_model(issue)
  end

  @doc """
  Per-complexity reasoning effort for an issue, read from the
  `agent.routing` value's effort segment (`backend:model:effort`), or `nil`
  when none is pinned. Effort has no `model:` label form (config-only, no
  new labels), so a `model:<backend>` override label — which pins
  backend/model explicitly and bypasses routing — also suppresses routing
  effort, keeping the effort consistent with the resolved backend/model.
  """
  @spec effort_for(Issue.t()) :: String.t() | nil
  def effort_for(%Issue{} = issue) do
    with nil <- override_backend(issue),
         value when is_binary(value) <- routing_value(issue) do
      RoutingValue.routing_effort(value)
    else
      _ -> nil
    end
  end

  defp override_model(%Issue{} = issue) do
    case override(issue) do
      {_backend, variant} -> variant
      nil -> nil
    end
  end

  @doc false
  @spec override_backend(Issue.t()) :: backend() | nil
  def override_backend(%Issue{} = issue) do
    case override(issue) do
      {backend, _variant} -> backend
      nil -> nil
    end
  end

  # First well-formed `model:<backend>[-<variant>]` label naming a known
  # backend, as `{backend, variant | nil}`. Unknown backends are skipped.
  @spec override(Issue.t()) :: {backend(), String.t() | nil} | nil
  defp override(%Issue{} = issue) do
    known = known_backends()

    issue
    |> Issue.label_names()
    |> Enum.find_value(&match_override(&1, known))
  end

  @spec match_override(term(), [backend()]) :: {backend(), String.t() | nil} | nil
  defp match_override(label, known) do
    case Regex.run(@model_override_label, to_string(label)) do
      [_, spec] -> resolve_backend_spec(spec, known)
      _ -> nil
    end
  end

  # Resolve `model:<spec>` to `{backend, variant | nil}`. A `model:<alias>`
  # spec (bare `remote` or `remote-<variant>`) is a remote FLAG,
  # not a backend selector, so it never resolves to a backend here — the
  # backend/model come from a companion `model:<backend>` tag while
  # `remote_control_forced?/1` reads the flag and dispatch swaps the transport.
  # Otherwise prefer the longest known backend the spec names exactly or
  # prefixes with `-`, so `claude-repl` wins over `claude`.
  @spec resolve_backend_spec(String.t(), [backend()]) :: {backend(), String.t() | nil} | nil
  defp resolve_backend_spec(spec, known) do
    if alias_spec?(spec), do: nil, else: resolve_known_backend_spec(spec, known)
  end

  @spec alias_spec?(String.t()) :: boolean()
  defp alias_spec?(spec) do
    Enum.any?(Map.keys(@backend_aliases), fn name ->
      spec == name or String.starts_with?(spec, name <> "-")
    end)
  end

  @spec resolve_known_backend_spec(String.t(), [backend()]) :: {backend(), String.t() | nil} | nil
  defp resolve_known_backend_spec(spec, known) do
    known
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.find_value(fn backend ->
      cond do
        spec == backend -> {backend, nil}
        String.starts_with?(spec, backend <> "-") -> {backend, String.replace_prefix(spec, backend <> "-", "")}
        true -> nil
      end
    end)
  end

  @doc false
  @spec routing_backend(Issue.t()) :: backend() | nil
  def routing_backend(%Issue{} = issue) do
    case routing_value(issue) do
      nil -> nil
      value -> value |> RoutingValue.split_routing_value() |> elem(0)
    end
  end

  # Model pinned by the complexity-routing value (`backend:model`), or nil.
  @doc false
  @spec routing_model(Issue.t()) :: String.t() | nil
  def routing_model(%Issue{} = issue) do
    case routing_value(issue) do
      nil -> nil
      value -> value |> RoutingValue.split_routing_value() |> elem(1)
    end
  end

  @doc """
  Whether the issue's complexity routes to a `+remote` value in the
  `agent.routing` table (e.g. `complexity:1 -> "claude:haiku+remote"`),
  forcing remote control for that routed default even without a
  `model:remote` label on the issue.
  """
  @spec routing_remote?(Issue.t()) :: boolean()
  def routing_remote?(%Issue{} = issue) do
    case routing_value(issue) do
      nil -> false
      value -> RoutingValue.routing_remote_flag?(value)
    end
  end

  defp routing_value(%Issue{} = issue) do
    case complexity_level(issue) do
      nil -> nil
      level -> Map.get(Config.agent_routing(), level)
    end
  end

  @doc """
  Highest `complexity:N` level on the issue, or `nil` when no
  well-formed complexity label is present.
  """
  @spec complexity_level(Issue.t()) :: pos_integer() | nil
  def complexity_level(%Issue{} = issue) do
    issue
    |> Issue.label_names()
    |> Enum.flat_map(fn
      label when is_binary(label) ->
        case Regex.run(@complexity_label, label) do
          [_, n] -> [String.to_integer(n)]
          _ -> []
        end

      _label ->
        []
    end)
    |> case do
      [] -> nil
      levels -> Enum.max(levels)
    end
  end

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

  @doc "Delivery-policy default: whether the backend supports operator interrupts."
  @spec can_interrupt?(backend()) :: boolean()
  def can_interrupt?(backend), do: fetch_backend!(backend).can_interrupt

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
  Whether an issue carries a `model:<alias>` label that forces remote
  control ON regardless of the global `agent.remote_control` opt-in
  default. Only the label-only aliases (e.g. `model:remote`) force
  RC; a bare `model:claude-repl` selects the transport but leaves RC to the
  global default.
  """
  @spec remote_control_forced?(Issue.t()) :: boolean()
  def remote_control_forced?(%Issue{} = issue) do
    alias_specs = MapSet.new(Map.keys(@backend_aliases))

    issue
    |> Issue.label_names()
    |> Enum.any?(fn label ->
      case Regex.run(@model_override_label, to_string(label)) do
        [_, spec] ->
          MapSet.member?(alias_specs, spec) or
            Enum.any?(alias_specs, &String.starts_with?(spec, &1 <> "-"))

        _ ->
          false
      end
    end)
  end

  @doc """
  The canonical operator-facing label that forces remote control on for an
  issue (`model:remote`). Added/removed by the AgentList `r` key to
  promote/demote a running agent; it is the durable source of truth for
  remote-ness across re-dispatches.
  """
  @spec remote_control_alias_label() :: String.t()
  def remote_control_alias_label, do: "model:remote"

  @doc """
  Whether the backend takes operator messages immediately (pass-through to
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

  @spec stop_session(map()) :: :ok
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
  defp adapter_for_session(_session), do: adapter(Config.agent_kind())

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

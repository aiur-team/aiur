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
  alias Aiur.Issue

  @type backend :: String.t()

  @type operator_payload :: %{required(:kind) => :text, required(:body) => String.t()}
  @type safe_checkpoint :: %{required(:kind) => atom(), optional(:method) => String.t()}

  @type checkpoint_callback_result ::
          :noop
          | {:deliver_text, String.t(), (map() -> any()), (term() -> any())}

  @callback start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback run_turn(map(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:paused, map()} | {:error, term()}
  @callback stop_session(map()) :: :ok
  @callback normalize_event(map()) :: map()
  @callback send_operator_message(map(), operator_payload()) ::
              {:ok, request_id :: integer()} | {:error, term()}

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

  # Label-only aliases that resolve to a real backend. `model:claude-remote`
  # is the operator-facing name for the persistent REPL backend (`claude-repl`)
  # and additionally forces remote-control ON for the issue (see
  # `remote_control_forced?/1`), overriding the global opt-in default. The
  # alias is resolved before the known-backend match so `claude-remote` is
  # never mis-split into backend `claude` + variant `remote`.
  @backend_aliases %{"claude-remote" => "claude-repl"}

  @doc """
  Registry of supported coding-agent backends. Each entry carries the
  modules, delivery-policy defaults, and the model variants worth
  seeding as `model:<backend>-<variant>` override labels for that
  backend. Adding a backend means adding one entry here.
  """
  @spec backends() :: %{backend() => map()}
  def backends do
    %{
      "codex" => %{
        adapter: Aiur.Codex.CodingAgent,
        transcript: Aiur.Codex.Transcript,
        can_interrupt: true,
        safe_checkpoints: [:notification, :tool_result],
        remote_control: false,
        models: ["gpt-5.5"]
      },
      "claude" => %{
        adapter: Aiur.Claude.CodingAgent,
        transcript: Aiur.Claude.Transcript,
        can_interrupt: true,
        safe_checkpoints: [:notification],
        remote_control: true,
        models: ["opus", "sonnet", "opus-4-8", "sonnet-4-6", "haiku-4-5"]
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
        models: ["opus", "sonnet", "opus-4-8", "sonnet-4-6", "haiku-4-5"]
      }
    }
  end

  @doc "Known backend keys, derived from the registry."
  @spec known_backends() :: [backend()]
  def known_backends, do: Map.keys(backends())

  @doc """
  Canonical `model:*` override labels worth auto-creating in a repo: a
  bare `model:<backend>` per known backend plus a
  `model:<backend>-<variant>` for each registry-listed model variant.
  Derived from the registry so new backends/models seed automatically.
  """
  @spec override_labels() :: [String.t()]
  def override_labels, do: override_labels(known_backends()) ++ alias_labels()

  @doc "Label-only alias override labels (e.g. `model:claude-remote`)."
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

  # Resolve `model:<spec>` to `{backend, variant | nil}`. Prefer the longest
  # known backend the spec names exactly or prefixes with `-`, so a
  # hyphenated backend (`claude-repl`) wins over a shorter one (`claude`)
  # before its trailing segment is mistaken for a variant.
  @spec resolve_backend_spec(String.t(), [backend()]) :: {backend(), String.t() | nil} | nil
  defp resolve_backend_spec(spec, known) do
    case Map.fetch(@backend_aliases, spec) do
      {:ok, backend} -> {backend, nil}
      :error -> resolve_alias_variant_spec(spec) || resolve_known_backend_spec(spec, known)
    end
  end

  # `model:claude-remote-sonnet` pins a model variant through the alias.
  # Without this clause the known-backend match would mis-split it into
  # backend `claude` + variant `remote-sonnet`.
  @spec resolve_alias_variant_spec(String.t()) :: {backend(), String.t()} | nil
  defp resolve_alias_variant_spec(spec) do
    Enum.find_value(@backend_aliases, fn {alias_name, backend} ->
      if String.starts_with?(spec, alias_name <> "-") do
        {backend, String.replace_prefix(spec, alias_name <> "-", "")}
      end
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
      value -> value |> Aiur.Config.Schema.split_routing_value() |> elem(0)
    end
  end

  # Model pinned by the complexity-routing value (`backend:model`), or nil.
  @doc false
  @spec routing_model(Issue.t()) :: String.t() | nil
  def routing_model(%Issue{} = issue) do
    case routing_value(issue) do
      nil -> nil
      value -> value |> Aiur.Config.Schema.split_routing_value() |> elem(1)
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
  Whether an issue carries a `model:<alias>` label that forces remote
  control ON regardless of the global `agent.remote_control` opt-in
  default. Only the label-only aliases (e.g. `model:claude-remote`) force
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
  issue (`model:claude-remote`). Added/removed by the AgentList `r` key to
  promote/demote a running agent; it is the durable source of truth for
  remote-ness across re-dispatches.
  """
  @spec remote_control_alias_label() :: String.t()
  def remote_control_alias_label, do: "model:claude-remote"

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

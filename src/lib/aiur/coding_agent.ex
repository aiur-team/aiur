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

  alias Aiur.CodingAgent.Models
  alias Aiur.CodingAgent.RouteCredentials
  alias Aiur.Config
  alias Aiur.Config.RoutingValue
  alias Aiur.Issue
  alias Aiur.ModelAvailability
  alias Aiur.ModelCatalog
  alias Aiur.ProviderMeterProbe
  alias Aiur.RunTelemetry.Lifecycle

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

  # `model:<effort>` per-ticket effort override labels. These set an agent's
  # reasoning effort independent of the per-complexity `agent.routing` table and
  # pair with (never select) a backend: the backend is resolved as usual and the
  # effort is applied on top. They share the `@model_override_label` namespace
  # but name an effort rather than a backend, so `override/1` skips them (an
  # effort is never a known backend) and only `override_effort/1` reads them.
  # Validity against the finally-dispatched backend is enforced at runtime
  # (`Aiur.AgentRunner.SessionLifecycle.supported_effort/2`), since the resolved
  # backend is per-issue state (and can swap to a remote transport).
  @effort_override_values ~w(low medium high xhigh max)

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
        family: "codex",
        default: true,
        rate_limit_fallback: "claude",
        rate_limit_fallback_target: false,
        skill_install: %{path: ".codex/skills", link_to: ".claude/skills"},
        configurable: true,
        init_order: 1,
        default_command: "codex app-server",
        model_catalog: &ModelCatalog.extract_codex/1,
        can_interrupt: true,
        safe_checkpoints: [:notification, :tool_result],
        control_application_confirmation: :confirmed,
        remote_control: false,
        # The codex app-server can rejoin a prior thread across an aiur restart
        # via `thread/resume` against its on-disk rollout, so a respawned
        # session continues rather than cold-starting (issue #378).
        resumable: true,
        models: [
          "gpt-5.6-sol",
          "gpt-5.6-terra",
          "gpt-5.6-luna",
          "gpt-5.5",
          "gpt-5.4",
          "gpt-5.5-mini",
          "gpt-5.4-mini"
        ],
        # codex has no generic model alias of its own, so aiur derives one per
        # family from the ids above and resolves it to the newest member (see
        # `resolve_model/2`). `codex:sol` therefore keeps following the latest
        # `*-sol` release instead of naming a version that will be retired.
        model_aliases: :derived,
        efforts: ["none", "low", "medium", "high", "xhigh", "max"],
        # Provider-level presentation descriptor, keyed by family, used by every
        # dashboard/strip surface so a new backend renders from its registry
        # entry rather than a per-provider `case`. `order` fixes card ordering.
        presentation: %{
          order: 0,
          label: "Codex",
          logo: "/provider-assets/codex-color.svg",
          token_icon: "/provider-assets/claude-token.svg",
          css_class: "is-codex",
          command_color: "#8fbcff",
          command_border: "rgba(143, 188, 255, 0.4)",
          unit_color: "#8fbcff",
          unit_border: "rgba(143, 188, 255, 0.4)",
          unit_background: "rgba(143, 188, 255, 0.12)"
        },
        pricing: %{
          dimensions: %{
            context_tier: %{allowed: [:short_context, :long_context], default: nil, required: true},
            cache_write_duration: %{allowed: [:not_applicable], default: :not_applicable, required: false}
          },
          component_dimensions: %{
            default: %{context_tier: [:short_context, :long_context], cache_write_duration: [:not_applicable]}
          }
        },
        usage: %{adapters: [Aiur.Usage.Headless.Codex.ThreadUsage, Aiur.Usage.Headless.Codex.TurnUsage]},
        meter_probe: &ProviderMeterProbe.probe_session/3,
        run_telemetry: &Lifecycle.decode_codex_operation/1,
        account_generation: %{
          backends: [:app_server],
          trusted_sources: [:codex_app_server],
          auth_modes: ~w(apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey)
        }
      },
      "claude" => %{
        adapter: Aiur.Claude.CodingAgent,
        transcript: Aiur.Claude.Transcript,
        family: "claude",
        config_default: true,
        rate_limit_fallback_target: true,
        skill_install: %{path: ".claude/skills"},
        configurable: true,
        init_order: 0,
        default_command: "aiur-claude",
        model_catalog: &ModelCatalog.extract_claude/1,
        install_hint: "install it with: npm install -g aiur-claude",
        can_interrupt: true,
        safe_checkpoints: [:notification],
        control_application_confirmation: :confirmed,
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
        # `claude --model` resolves `opus`/`sonnet`/`haiku` to the newest
        # version in that family itself, so the generic tags above are passed
        # through untouched rather than pinned to a version aiur happens to
        # know about.
        model_aliases: :native,
        efforts: [],
        presentation: %{
          order: 1,
          label: "Claude",
          logo: "/provider-assets/claude-symbol.svg",
          token_icon: "/provider-assets/codex-token.svg",
          css_class: "is-claude",
          command_color: "#f2a76b",
          command_border: "rgba(242, 167, 107, 0.4)",
          unit_color: "#f0a878",
          unit_border: "rgba(240, 168, 120, 0.4)",
          unit_background: "rgba(240, 168, 120, 0.12)"
        },
        pricing: %{
          dimensions: %{
            context_tier: %{allowed: [:not_applicable], default: :not_applicable, required: false},
            cache_write_duration: %{allowed: [:five_minutes, :one_hour, :not_applicable], default: nil, required: true}
          },
          component_dimensions: %{
            default: %{context_tier: [:not_applicable], cache_write_duration: [:not_applicable]},
            cache_creation_input: %{context_tier: [:not_applicable], cache_write_duration: [:five_minutes, :one_hour]}
          }
        },
        usage: %{adapters: [Aiur.Usage.Headless.Claude.RequestUsage]},
        meter_probe: &ProviderMeterProbe.probe_usage_api/3,
        run_telemetry: &Lifecycle.decode_claude_operation/1,
        account_generation: %{
          backends: [:app_server],
          trusted_sources: [:claude_app_server],
          auth_modes: ~w(subscription api_key)
        }
      },
      "claude-repl" => %{
        adapter: Aiur.Claude.ReplAgent,
        transcript: Aiur.Claude.Transcript,
        family: "claude",
        # A persistent REPL carries the primary session handle. It must never
        # be selected as a usage-limit replacement for a different session.
        rate_limit_fallback_target: false,
        # The REPL is launched by its adapter rather than the init wizard, but
        # rate-limit fallback still needs a registry-owned readiness command.
        default_command: "claude",
        model_catalog: &ModelCatalog.extract_claude/1,
        model_catalog_backend: "claude",
        # Executor messages are typed straight into the live pane and the
        # agent's native input queue folds them in, so there is no
        # checkpoint to hold at — `safe_checkpoints` stays empty and
        # delivery is immediate. Interrupt is the explicit out-of-band
        # action: `ReplAgent.interrupt/1` sends Ctrl+C to the pane, cutting
        # the active turn so a queued message drains right away.
        can_interrupt: true,
        safe_checkpoints: [],
        immediate_delivery: true,
        control_application_confirmation: :confirmed,
        remote_control: true,
        # A tmux/RC start failure must never strand an issue: a failed
        # claude-repl spawn falls back once to the headless claude
        # backend. Declared here so the fallback never lives in a
        # dispatch `case`.
        fallback_backend: "claude",
        run_telemetry: &Lifecycle.decode_claude_operation/1,
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
        model_aliases: :native,
        efforts: ["low", "medium", "high", "xhigh", "max"]
      }
    }
    |> Map.merge(Aiur.OpenAICompat.Registry.entries())
    |> maybe_add_test_backend()
  end

  # Acceptance fixture for registry consumers. It intentionally lives only in
  # the test build and is added exactly like a production provider: no caller
  # receives a fake-specific branch or fixture hook.
  if Mix.env() == :test do
    defp maybe_add_test_backend(backends) do
      Map.put(backends, "fake", %{
        adapter: Aiur.Codex.CodingAgent,
        transcript: Aiur.Codex.Transcript,
        family: "fake",
        skill_install: %{path: ".fake/skills"},
        rate_limit_fallback_target: true,
        configurable: true,
        init_order: 99,
        default_command: "fake-agent --serve",
        models: ["fake-1"],
        model_aliases: :native,
        efforts: [],
        can_interrupt: false,
        safe_checkpoints: [],
        control_application_confirmation: :confirmed,
        remote_control: false,
        resumable: false,
        presentation: %{
          order: 99,
          label: "Fake",
          logo: "/provider-assets/codex-color.svg",
          token_icon: "/provider-assets/codex-token.svg",
          css_class: "is-fake",
          command_color: "#8fbcff",
          command_border: "rgba(143, 188, 255, 0.4)",
          unit_color: "#8fbcff",
          unit_border: "rgba(143, 188, 255, 0.4)",
          unit_background: "rgba(143, 188, 255, 0.12)"
        },
        pricing: %{
          dimensions: %{
            context_tier: %{allowed: [:not_applicable], default: :not_applicable, required: false},
            cache_write_duration: %{allowed: [:not_applicable], default: :not_applicable, required: false}
          },
          component_dimensions: %{default: %{context_tier: [:not_applicable], cache_write_duration: [:not_applicable]}}
        },
        usage: %{adapters: [Aiur.Usage.Headless.Fake.RequestUsage]},
        account_generation: %{backends: [:app_server], trusted_sources: [:fake_app_server], auth_modes: ["fake"]}
      })
    end
  else
    defp maybe_add_test_backend(backends), do: backends
  end

  @doc "Known backend keys, derived from the registry."
  @spec known_backends() :: [backend()]
  def known_backends, do: Map.keys(backends())

  @doc """
  Whether a backend refuses to pick a model for itself, so every route to it
  must name one. True for an aggregator that fronts a whole catalog
  (OpenRouter) rather than a product: it registers models but deliberately no
  `default_model`, because there is no defensible default across hundreds of
  differently-priced upstreams. Derived from the registry rather than declared,
  so a new aggregator cannot forget the flag and regress to a runtime
  `:missing_model` at dispatch.
  """
  @spec model_required?(backend()) :: boolean()
  def model_required?(backend) do
    case get_in(backends(), [backend, :openai_compat]) do
      %{} = compat -> is_nil(Map.get(compat, :default_model))
      _ -> false
    end
  end

  @doc "Backends currently eligible for dispatch, including explicit config opt-ins."
  @spec dispatchable_backends(map()) :: [backend()]
  def dispatchable_backends(backend_configs \\ %{}) when is_map(backend_configs) do
    backends()
    |> Enum.filter(fn {backend, entry} ->
      config = Map.get(backend_configs, backend, %{})
      configured = Map.get(config, "enabled", Map.get(config, :enabled))
      if is_boolean(configured), do: configured, else: Map.get(entry, :dispatch_enabled_by_default, true)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Backends approved by their registry entry as rate-limit fallback targets."
  @spec rate_limit_fallback_targets() :: [backend()]
  def rate_limit_fallback_targets do
    backends()
    |> Enum.filter(fn {_backend, entry} -> Map.get(entry, :rate_limit_fallback_target, false) end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "The registry-selected default backend used when no config section chooses one."
  @spec default_backend() :: backend()
  def default_backend do
    backends()
    |> Enum.find_value(fn {backend, entry} -> if Map.get(entry, :default, false), do: backend end)
    |> Kernel.||(known_backends() |> List.first())
  end

  @doc "The registry-selected legacy configuration default."
  @spec default_config_backend() :: backend()
  def default_config_backend do
    backends()
    |> Enum.find_value(fn {backend, entry} -> if Map.get(entry, :config_default, false), do: backend end)
    |> Kernel.||(default_backend())
  end

  @doc "Registry-selected fallback for the default backend's rate-limit reroute."
  @spec default_rate_limit_fallback() :: backend() | nil
  def default_rate_limit_fallback do
    backends()
    |> Map.get(default_backend(), %{})
    |> Map.get(:rate_limit_fallback)
  end

  @doc "Workspace skill-install locations declared by registered backends."
  @spec skill_install_locations() :: [%{optional(:link_to) => String.t(), path: String.t()}]
  def skill_install_locations do
    backends()
    |> Map.values()
    |> Enum.map(&Map.get(&1, :skill_install))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.path)
  end

  @doc "Backends selectable during init, ordered by registry preference."
  @spec configurable_backends() :: [backend()]
  def configurable_backends do
    dispatchable = dispatchable_backends()

    backends()
    |> Enum.filter(fn {backend, entry} -> backend in dispatchable and Map.get(entry, :configurable, false) end)
    |> Enum.sort_by(fn {backend, entry} -> {Map.get(entry, :init_order, 9_999), backend} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Stable agent family for trusted Decision provenance, if the backend is known."
  @spec family_for(backend()) :: String.t() | nil
  def family_for(backend) do
    case Map.fetch(backends(), backend) do
      {:ok, entry} -> Map.get(entry, :family)
      :error -> nil
    end
  end

  @typedoc """
  A provider descriptor combines presentation and its registry-owned metering,
  pricing, and account-generation capabilities. The resolved `provider` family
  atom and stable `order` keep card layout deterministic.
  """
  @type provider_descriptor :: %{
          provider: atom(),
          order: non_neg_integer(),
          label: String.t(),
          logo: String.t(),
          token_icon: String.t(),
          css_class: String.t(),
          command_color: String.t(),
          command_border: String.t(),
          unit_color: String.t(),
          unit_border: String.t(),
          unit_background: String.t(),
          pricing: map(),
          usage: map(),
          account_generation: map()
        }

  @doc """
  Provider presentation descriptors, one per family that declares a
  `:presentation` entry in the registry, ordered by their `order` field.
  Presentation is family-level (`claude` and `claude-repl` share one), so the
  list is deduplicated by provider family. Drives every provider-facing surface
  so a new backend renders from its registry entry with no per-provider `case`.
  """
  @spec provider_descriptors() :: [provider_descriptor()]
  def provider_descriptors do
    backends()
    |> Map.values()
    |> Enum.flat_map(fn entry ->
      case Map.get(entry, :presentation) do
        %{} = presentation ->
          [
            presentation
            |> Map.put(:provider, String.to_atom(entry.family))
            |> Map.put(:pricing, Map.get(entry, :pricing, %{}))
            |> Map.put(:usage, Map.get(entry, :usage, %{}))
            |> Map.put(:account_generation, Map.get(entry, :account_generation, %{}))
          ]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.provider)
    |> Enum.sort_by(& &1.order)
  end

  @doc "Provider family atoms with a presentation descriptor, in card order."
  @spec provider_families() :: [atom()]
  def provider_families, do: Enum.map(provider_descriptors(), & &1.provider)

  @doc """
  Map from each registered headless backend name to its provider family atom
  (e.g. `%{"codex" => :codex, "claude" => :claude}`). A backend name need not
  match its family name, so the map is derived from registry keys rather than
  presentation descriptors. Transports without usage adapters (such as the
  REPL) are deliberately excluded.
  """
  @spec provider_family_map() :: %{String.t() => atom()}
  def provider_family_map do
    for {backend, %{family: family, usage: %{adapters: adapters}}} <- backends(),
        is_list(adapters),
        adapters != [],
        into: %{},
        do: {backend, String.to_atom(family)}
  end

  @doc "Registry-owned usage backend and transport for a headless backend."
  @spec usage_context(backend()) :: %{backend: atom(), transport: atom()} | nil
  def usage_context(backend) when is_binary(backend) do
    case Map.get(backends(), backend) do
      %{usage: %{adapters: adapters}} = entry when is_list(adapters) and adapters != [] ->
        %{
          backend: Map.get(entry, :usage_backend, :app_server),
          transport: Map.get(entry, :usage_transport, :app_server)
        }

      _ ->
        nil
    end
  end

  def usage_context(_backend), do: nil

  @doc "All registry-declared headless usage backend identities."
  @spec usage_backends() :: [atom()]
  def usage_backends do
    backends()
    |> Map.keys()
    |> Enum.map(&usage_context/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.backend)
    |> Enum.uniq()
  end

  @doc "All registry-declared headless usage transport identities."
  @spec usage_transports() :: [atom()]
  def usage_transports do
    backends()
    |> Map.keys()
    |> Enum.map(&usage_context/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.transport)
    |> Enum.uniq()
  end

  @doc "Presentation descriptor for one provider family atom, or `nil` if none."
  @spec provider_descriptor(atom() | String.t() | nil) :: provider_descriptor() | nil
  def provider_descriptor(provider) when is_atom(provider) do
    Enum.find(provider_descriptors(), &(&1.provider == provider))
  end

  def provider_descriptor(provider) when is_binary(provider) do
    Enum.find(provider_descriptors(), &(Atom.to_string(&1.provider) == provider))
  end

  def provider_descriptor(_provider), do: nil

  @doc "Registry-supplied pricing policy for one provider family, or `nil` when it is not metered."
  @spec provider_pricing(atom()) :: map() | nil
  def provider_pricing(provider) when is_atom(provider) do
    case provider_descriptor(provider) do
      %{pricing: pricing} when is_map(pricing) -> pricing
      _ -> nil
    end
  end

  @doc "Registry-supplied account-generation policy for one provider family."
  @spec provider_account_generation(atom()) :: map() | nil
  def provider_account_generation(provider) when is_atom(provider) do
    case provider_descriptor(provider) do
      %{account_generation: policy} when is_map(policy) -> policy
      _ -> nil
    end
  end

  @doc "Primary registry-declared meter backend for a provider family."
  @spec provider_meter_backend(atom()) :: atom()
  def provider_meter_backend(provider) when is_atom(provider) do
    provider
    |> provider_account_generation()
    |> then(&get_in(&1 || %{}, [:backends]))
    |> case do
      [backend | _] when is_atom(backend) -> backend
      _ -> :app_server
    end
  end

  @doc "Registry probe callback and backend for one provider family, if declared."
  @spec provider_meter_probe(atom()) :: {backend(), function()} | nil
  def provider_meter_probe(provider) when is_atom(provider) do
    Enum.find_value(backends(), fn {backend, entry} ->
      with %{provider: ^provider} <- provider_descriptor(entry.family),
           probe when is_function(probe, 3) <- Map.get(entry, :meter_probe) do
        {backend, probe}
      else
        _ -> nil
      end
    end)
  end

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
  def override_labels,
    do: override_labels(dispatchable_backends(Config.agent_backend_configs())) ++ alias_labels() ++ override_effort_labels()

  @doc "Label-only alias override labels (e.g. `model:remote`)."
  @spec alias_labels() :: [String.t()]
  def alias_labels, do: Enum.map(Map.keys(@backend_aliases), &"model:#{&1}")

  @doc """
  Backend-independent `model:<effort>` override labels (e.g. `model:xhigh`),
  one per supported effort value. They set an issue's reasoning effort
  independent of the per-complexity routing table; see `effort_for/1`.
  """
  @spec override_effort_labels() :: [String.t()]
  def override_effort_labels, do: Enum.map(@effort_override_values, &"model:#{&1}")

  @doc """
  `override_labels/0` restricted to the given backends. Each backend
  contributes only its own `model:<backend>[-<variant>]` labels, so a
  hyphenated backend (`claude-repl`) is never seeded by selecting a
  shorter-named one (`claude`).

  Derived family aliases are seeded ahead of the pinned versions, because
  the alias is the tag an Executor should reach for by default — a pinned
  tag expires with its version.
  """
  @spec override_labels([backend()]) :: [String.t()]
  def override_labels(selected) do
    backends()
    |> Map.take(selected)
    |> Enum.flat_map(fn {backend, entry} ->
      variant_labels = Enum.map(seedable_models(backend, entry), &"model:#{backend}-#{&1}")
      ["model:#{backend}" | variant_labels]
    end)
  end

  @doc "The concrete models a backend's registry entry lists. Stale by design; see `known_model?/2`."
  @spec models(backend()) :: [String.t()]
  def models(backend), do: backends() |> Map.get(backend, %{}) |> Map.get(:models, [])

  @doc """
  Generic model tags for a backend that name a family rather than a version.
  Empty when the backend's own CLI already resolves aliases (`:native`, the
  default) — those alias strings are simply part of `models` and are handed
  to the CLI verbatim.
  """
  @spec model_aliases(backend()) :: [String.t()]
  def model_aliases(backend) do
    entry = Map.get(backends(), backend, %{})

    case Map.get(entry, :model_aliases, :native) do
      :derived -> Models.aliases(Map.get(entry, :models, []))
      _native -> []
    end
  end

  @doc """
  Every model string worth offering or seeding a label for on a backend:
  its derived family aliases first, then the concrete versions.
  """
  @spec seedable_models(backend()) :: [String.t()]
  def seedable_models(backend), do: seedable_models(backend, Map.get(backends(), backend, %{}))

  defp seedable_models(backend, entry), do: model_aliases(backend) ++ Map.get(entry, :models, [])

  @doc """
  Turns a generic model tag into the newest concrete model in that family,
  and passes anything else through unchanged.

  Only backends whose aliases aiur derives (`model_aliases: :derived`) are
  rewritten. A `:native` backend's alias is left alone so its own CLI
  resolves it — re-pointing `opus` at whichever version aiur's registry
  lists would reintroduce exactly the staleness the alias avoids. An
  unrecognized string is also passed through untouched: aiur's model list
  is expected to lag the provider, so a model it has never heard of is far
  more likely new than wrong (see
  `Aiur.AgentRunner.SessionLifecycle`, which surfaces it to the Executor).
  """
  @spec resolve_model(backend(), String.t() | nil) :: String.t() | nil
  def resolve_model(backend, nil), do: backend_default_model(backend)

  def resolve_model(backend, model) when is_binary(model) do
    entry = Map.get(backends(), backend, %{})

    case Map.get(entry, :model_aliases, :native) do
      :derived -> Models.latest(Map.get(entry, :models, []), model) || model
      _native -> model
    end
  end

  # A bare `model:<backend>` override selects the backend but pins no model, and
  # the routing table may not name this backend at all (routing is codex/claude
  # shaped). Fall back to the backend's registered default so the session starts
  # with a real model instead of `nil` (which would otherwise surface as an
  # `unsupported_model` attention). OpenAI-compatible backends declare their
  # default under `openai_compat.default_model`.
  defp backend_default_model(backend) do
    get_in(backends(), [backend, :openai_compat, :default_model])
  end

  @doc """
  Whether a model string is one this build of aiur knows about for a
  backend — a listed version or a derived family alias. A `false` answer
  means "not in aiur's list", not "invalid": the list goes stale by design.
  """
  @spec known_model?(backend(), term()) :: boolean()
  def known_model?(backend, model) when is_binary(model), do: model in seedable_models(backend)
  def known_model?(_backend, _model), do: false

  @doc """
  Resolve the backend for an issue: a `model:<backend>` override label
  wins, then the `complexity:` label mapped through `agent.routing`,
  then the global `agent.kind` fallback.
  """
  @spec backend_for(Issue.t()) :: backend()
  def backend_for(%Issue{} = issue) do
    issue.selected_backend || override_backend(issue) || routing_backend(issue) || Config.agent_kind()
  end

  @spec select_for_dispatch(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:all_limited, [backend()]}
  def select_for_dispatch(%Issue{} = issue, opts \\ []) do
    if (is_binary(issue.selected_backend) or override_backend(issue)) || routing_backend(issue) do
      {:ok, issue}
    else
      candidates = eligible_routes(opts)

      cond do
        candidates == [] -> {:ok, issue}
        route = ModelAvailability.first_available(candidates, opts) -> {:ok, select_route(issue, route)}
        true -> {:all_limited, candidates}
      end
    end
  end

  # The candidate routes for one claim. `agent.priority` is read **fresh per
  # claim and reduced through an ordered chain**, never treated as a fixed
  # literal resolved once at config load: that is what lets a later policy drop
  # or reorder entries per dispatch.
  #
  # Two policies ship here — the backend must be dispatchable, and the route
  # must have its credential — and `:route_policies` is the seam for the rest.
  # #1456's peak-pricing policy is the intended next occupant: it needs to
  # compare entries by cost at the moment of selection, which it can, because a
  # route already resolves to a price identity via `route_price_identity/1`.
  # A policy that returns [] falls through to `{:ok, issue}` (dispatch with no
  # pinned route) rather than stranding the claim.
  defp eligible_routes(opts) do
    Keyword.get(opts, :backends, Config.switch_model_on_ratelimit())
    |> Enum.filter(&(RoutingValue.routing_backend(&1) in configured_backends(opts) and RouteCredentials.usable?(&1, opts)))
    |> apply_route_policies(opts)
  end

  defp apply_route_policies(routes, opts) do
    opts
    |> Keyword.get(:route_policies, [])
    |> Enum.reduce(routes, fn policy, acc -> policy.(acc) end)
  end

  @doc """
  The price-table identity a route bills under: the billing-path provider and
  the model slug, which together with the usual dimensions key
  `Aiur.Usage.PriceTable.lookup/2`.

  The provider is the **route's own backend family**, never the upstream that
  ultimately served the request — spend through OpenRouter is billed by
  OpenRouter at OpenRouter's rates even when the selected endpoint is
  Anthropic's. Exposing this as a pure function of the route is what lets a
  cost-aware selection policy (#1456) compare candidates before dispatch
  instead of reconstructing cost after the fact.

  `nil` for the model half means the route pins no model and the backend's own
  default applies.
  """
  @spec route_price_identity(String.t()) :: %{provider: atom() | nil, model: String.t() | nil}
  def route_price_identity(route) when is_binary(route) do
    backend = RoutingValue.routing_backend(route)
    model = RoutingValue.routing_model(route)

    %{
      provider: backend && family_for(backend) && String.to_existing_atom(family_for(backend)),
      model: resolve_model(backend, model)
    }
  rescue
    ArgumentError -> %{provider: nil, model: RoutingValue.routing_model(route)}
  end

  # A route carries both halves; persisting only the backend would let session
  # start-up re-resolve a different model than the one selection chose.
  defp select_route(issue, route) do
    %{issue | selected_backend: RoutingValue.routing_backend(route), selected_model: RoutingValue.routing_model(route)}
  end

  defp configured_backends(opts) do
    Keyword.get_lazy(opts, :configured_backends, fn ->
      (Config.agent_priority_backends() ++
         [Config.agent_kind() | Enum.map(Config.agent_routing(), fn {_level, value} -> RoutingValue.routing_backend(value) end)])
      |> Enum.filter(&(&1 in known_backends()))
      |> Enum.uniq()
    end)
  end

  @doc """
  Model string an issue asks for, or `nil` for "the backend's own default"
  (which `resolve_model/2` supplies).

  In precedence order: a variant pinned on a `model:<backend>-<variant>`
  override label (e.g. `model:claude-opus-4-8` -> `"opus-4-8"`), then the
  `complexity:` routing model, then `nil`. A bare `model:<backend>` names
  only a backend, so it pins no model of its own and defers to the routing
  model when routing names that same backend.
  """
  @spec model_for(Issue.t()) :: String.t() | nil
  # `backend_for/1` already resolves `selected_backend` ahead of everything
  # else, so the model half of the same selected route has to win here too —
  # otherwise dispatch picks `openrouter:anthropic/claude-sonnet-5` and the
  # session starts on whatever the routing table happens to say instead.
  def model_for(%Issue{selected_model: model}) when is_binary(model) and model != "", do: model

  def model_for(%Issue{} = issue) do
    case override_backend(issue) do
      # With no override, the complexity-routing value names the model for the
      # routed backend. A *bare* override names only a backend, so the routing
      # value is the more specific answer and is still deferred to when it
      # targets that same backend: a `model:codex` override still wants the
      # codex routing model, while a `model:deepseek` override must not inherit
      # a codex-shaped model that is invalid for it. A bare override for a
      # backend the routing table never names (an OpenAI-compatible one)
      # therefore yields nil, and `resolve_model/2` supplies the backend default.
      nil ->
        override_model(issue) || routing_model(issue)

      backend ->
        override_model_for(issue, backend)
    end
  end

  # `backend_for/1` resolves `issue.selected_backend` ahead of the override
  # label, so a variant pinned for the overridden backend must never be handed
  # to a different one: `resolve_model/2` forwards a string it does not
  # recognise untouched, so it would reach that CLI verbatim. Nothing sets both
  # today — `select_for_dispatch/2` and the rate-limit fallback only assign a
  # backend when there is no override — so this holds the invariant rather than
  # serving live traffic.
  @spec override_model_for(Issue.t(), backend()) :: String.t() | nil
  defp override_model_for(%Issue{selected_backend: selected}, backend)
       when is_binary(selected) and selected != backend,
       do: nil

  # A variant pinned on the override label is the operator naming a model
  # outright, so it wins even when routing targets the same backend — the
  # add-agent modal always writes `complexity:N` beside
  # `model:<backend>-<variant>`, and deferring to routing here discarded the
  # operator's choice with no feedback. It also used to discard the variant for
  # nothing when routing named the backend but no model (`4 => "claude"`). The
  # variant is passed through verbatim: `opus` stays the floating family alias
  # the operator picked and is only widened to a concrete version by
  # `resolve_model/2`, which knows which backends derive their aliases.
  defp override_model_for(%Issue{} = issue, backend) do
    case {override_model(issue), routing_backend(issue)} do
      {nil, ^backend} -> routing_model(issue)
      {nil, _other} -> nil
      {variant, _any} -> variant
    end
  end

  @doc """
  Reasoning effort for an issue, in precedence order: a per-ticket
  `model:<effort>` override label (e.g. `model:xhigh`) wins, then the
  per-complexity `agent.routing` value's effort segment
  (`backend:model:effort`), then `nil` (the dispatched backend's own
  default). The override label sets effort independent of routing and pairs
  with the resolved backend, so it applies even alongside a
  `model:<backend>` override — which otherwise suppresses routing effort to
  keep the routed effort consistent with the explicitly pinned
  backend/model. The resolved value is a pure read of the labels/routing;
  validity against the finally-dispatched backend is enforced at dispatch
  (`Aiur.AgentRunner.SessionLifecycle.supported_effort/2`).
  """
  @spec effort_for(Issue.t()) :: String.t() | nil
  def effort_for(%Issue{} = issue) do
    override_effort(issue) || routing_effort(issue)
  end

  # Per-complexity routing effort, suppressed when a `model:<backend>`
  # override label is present (that label bypasses routing entirely).
  @spec routing_effort(Issue.t()) :: String.t() | nil
  defp routing_effort(%Issue{} = issue) do
    with nil <- override_backend(issue),
         value when is_binary(value) <- routing_value(issue) do
      RoutingValue.routing_effort(value)
    else
      _ -> nil
    end
  end

  # First `model:<effort>` override label naming a supported effort value, or
  # nil. An effort label never selects a backend (see `override/1`).
  @spec override_effort(Issue.t()) :: String.t() | nil
  defp override_effort(%Issue{} = issue) do
    issue
    |> Issue.label_names()
    |> Enum.find_value(&match_effort_override/1)
  end

  @spec match_effort_override(term()) :: String.t() | nil
  defp match_effort_override(label) do
    case Regex.run(@model_override_label, to_string(label)) do
      [_, spec] -> if spec in @effort_override_values, do: spec
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
    known = dispatchable_backends(Config.agent_backend_configs())

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

  @doc "Delivery-policy default: whether the backend supports Executor interrupts."
  @spec can_interrupt?(backend()) :: boolean()
  def can_interrupt?(backend), do: fetch_backend!(backend).can_interrupt

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

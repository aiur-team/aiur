defmodule Aiur.CodingAgent.ModelGrammar do
  @moduledoc """
  `model:*` label grammar and per-backend model lists: efforts, override
  labels, model aliases and alias resolution.

  The public API is `Aiur.CodingAgent`, which delegates here.
  """

  alias Aiur.CodingAgent.Models
  alias Aiur.CodingAgent.ProvidersView
  alias Aiur.Config
  alias Aiur.ModelDiscovery

  @type backend :: String.t()

  # `model:<backend>` selects a backend with its configured default model.
  # `model:<backend>-<variant>` additionally pins a model string passed to
  # that backend (e.g. `model:claude-opus-4-8`). The whole spec charset is
  # restricted to word/dot/dash so it is safe to splice into a backend's
  # spawned command without shell-injection risk. The spec itself is resolved
  # by `Aiur.CodingAgent.ModelLabel`: longest backend prefix first (so
  # `claude-repl` is not mis-split into `claude` + `repl`), and a bare
  # `model:<name>` resolves through the installed CLIs' model catalogues.
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

  @doc false
  @spec model_override_label() :: Regex.t()
  def model_override_label, do: @model_override_label

  @doc false
  @spec alias_specs() :: [String.t()]
  def alias_specs, do: Map.keys(@backend_aliases)

  @doc false
  @spec effort_override_values() :: [String.t()]
  def effort_override_values, do: @effort_override_values

  @doc """
  The valid reasoning-effort values for a backend, derived from the
  registry. Unknown backends have no efforts. Used by per-complexity
  routing validation (`Aiur.Config.Schema.AgentValidation.validate_agent_routing/2`) and
  the `aiur init` wizard to offer backend-appropriate options.
  """
  @spec efforts(backend()) :: [String.t()]
  def efforts(backend) do
    case Map.fetch(ProvidersView.backends(), backend) do
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
    do: override_labels(ProvidersView.dispatchable_backends(Config.agent_backend_configs())) ++ alias_labels() ++ override_effort_labels()

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
  `override_labels/0` restricted to the given backends: a `model:<backend>`
  per backend, then a bare `model:<family>` per model family those backends
  offer (`model:opus`, `model:sol`). No version-specific label is seeded — a
  pinned tag expires with its version, while a family tag keeps resolving to
  the newest release and a bare name the installed CLI reports resolves
  without any label being created in advance.

  `ids_for` supplies each backend's model ids; `aiur init` passes what the
  installed CLI reported, falling back to the registry list.
  """
  @spec override_labels([backend()], (backend() -> [String.t()])) :: [String.t()]
  def override_labels(selected, ids_for \\ &models/1) do
    chosen = ProvidersView.backends() |> Map.take(selected) |> Map.keys()
    families = chosen |> Enum.flat_map(&family_names(ids_for.(&1))) |> Enum.uniq()

    Enum.map(chosen, &"model:#{&1}") ++ Enum.map(families, &"model:#{&1}")
  end

  # A family is seeded only when its label would mean that family: never when it
  # would read as a backend, the remote flag, or an effort. Ids with no family
  # (`default`, `sonnet[1m]`) contribute nothing.
  defp family_names(ids) do
    reserved = ProvidersView.known_backends() ++ Map.keys(@backend_aliases) ++ @effort_override_values

    ids
    |> Enum.map(&Models.family/1)
    |> Enum.reject(&(is_nil(&1) or &1 in reserved))
    |> Enum.uniq()
  end

  @doc "The concrete models a backend's registry entry lists. Stale by design; see `known_model?/2`."
  @spec models(backend()) :: [String.t()]
  def models(backend), do: ProvidersView.backends() |> Map.get(backend, %{}) |> Map.get(:models, [])

  @doc """
  Generic model tags for a backend that name a family rather than a version.
  Empty when the backend's own CLI already resolves aliases (`:native`, the
  default) — those alias strings are simply part of `models` and are handed
  to the CLI verbatim.
  """
  @spec model_aliases(backend()) :: [String.t()]
  def model_aliases(backend) do
    entry = Map.get(ProvidersView.backends(), backend, %{})

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
  def seedable_models(backend), do: seedable_models(backend, Map.get(ProvidersView.backends(), backend, %{}))

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
  @spec resolve_model(backend(), String.t() | nil, keyword()) :: String.t() | nil
  def resolve_model(backend, model, opts \\ [])
  def resolve_model(backend, nil, _opts), do: backend_default_model(backend)

  def resolve_model(backend, model, opts) when is_binary(model) do
    entry = Map.get(ProvidersView.backends(), backend, %{})

    case Map.get(entry, :model_aliases, :native) do
      :derived -> Models.latest(resolvable_ids(backend, entry, opts), model) || model
      _native -> model
    end
  end

  # A bare `model:<backend>` override selects the backend but pins no model, and
  # the routing table may not name this backend at all (routing is codex/claude
  # shaped). Fall back to the backend's registered default so the session starts
  # with a real model instead of `nil` (which would otherwise surface as an
  # `unsupported_model` attention). OpenAI-compatible backends declare their
  # default under `openai_compat.default_model`.
  # A family resolves against concrete ids only — the registry list plus, for a
  # backend whose own CLI reports its models, the ids it reported. Derived
  # aliases are never in this list: `Models.latest/2` treats a family that is
  # itself listed as a pin and would hand the bare alias to the CLI. HTTP
  # catalogues (OpenRouter) stay registry-only so a routed family never moves
  # to a differently priced upstream on its own.
  defp resolvable_ids(backend, entry, opts) do
    curated = Map.get(entry, :models, [])

    if is_function(Map.get(entry, :model_catalog), 1) do
      cached = Keyword.get(opts, :cached_models, &ModelDiscovery.cached_models/1).(backend)
      curated ++ (cached -- curated)
    else
      curated
    end
  end

  defp backend_default_model(backend) do
    get_in(ProvidersView.backends(), [backend, :openai_compat, :default_model])
  end

  @doc """
  Whether a model string is one this build of aiur knows about for a
  backend — a listed version or a derived family alias. A `false` answer
  means "not in aiur's list", not "invalid": the list goes stale by design.
  """
  @spec known_model?(backend(), term()) :: boolean()
  def known_model?(backend, model) when is_binary(model), do: model in seedable_models(backend)
  def known_model?(_backend, _model), do: false
end

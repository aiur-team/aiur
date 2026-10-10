defmodule Aiur.CodingAgent.Routing do
  @moduledoc """
  Per-issue backend, model and effort selection: `model:` override labels,
  the `agent.routing` complexity table, the `agent.priority` route chain and
  its peak-pricing policy.

  The public API is `Aiur.CodingAgent`, which delegates here.
  """

  alias Aiur.CodingAgent.ModelGrammar
  alias Aiur.CodingAgent.ModelLabel
  alias Aiur.CodingAgent.ProvidersView
  alias Aiur.CodingAgent.RouteCredentials
  alias Aiur.Config
  alias Aiur.Config.RoutingValue
  alias Aiur.Issue
  alias Aiur.ModelAvailability
  alias Aiur.ModelDiscovery
  alias Aiur.Usage.PriceTable.Data
  alias Aiur.Usage.PriceTable.Window

  @type backend :: String.t()

  @complexity_label ~r/^complexity:(\d+)$/

  @doc """
  Resolve the backend for an issue: a `model:<backend>` override label
  wins, then the `complexity:` label mapped through `agent.routing`,
  then the global `agent.kind` fallback.
  """
  @spec backend_for(Issue.t(), keyword()) :: backend()
  def backend_for(%Issue{} = issue, opts \\ []) do
    issue.selected_backend || override_backend(issue, opts) || routing_backend(issue) || Config.agent_kind()
  end

  @spec select_for_dispatch(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:all_limited, [backend()]}
  def select_for_dispatch(%Issue{} = issue, opts \\ []) do
    cond do
      # A pin is intent: an operator's `model:` label, or the backend a
      # rate-limit fallback has already moved this claim onto. It dispatches
      # whatever the ledger says.
      is_binary(issue.selected_backend) or override_backend(issue) ->
        {:ok, issue}

      # A backend the `complexity:` routing chose is not a pin, it is a
      # default, and a default onto an exhausted account is a dispatch that can
      # only refuse. Park the claim the way an exhausted priority chain does:
      # `model_fallback_waiting` releases it as soon as the backend recovers.
      #
      # Before this, a routed backend short-circuited with no availability
      # check at all, so a fleet whose routing names one backend kept
      # dispatching into its own account limit.
      backend = Keyword.get_lazy(opts, :routing_backend, fn -> routing_backend(issue) end) ->
        if ModelAvailability.available?(backend, opts),
          do: {:ok, issue},
          else: {:all_limited, [backend]}

      true ->
        candidates = eligible_routes(opts)

        cond do
          candidates == [] ->
            default_backend_decision(issue, opts)

          route = ModelAvailability.first_available(candidates, opts) ->
            {:ok, select_route(issue, route)}

          true ->
            {:all_limited, candidates}
        end
    end
  end

  defp default_backend_decision(issue, opts) do
    backend = Keyword.get_lazy(opts, :default_backend, &Config.agent_kind/0)

    if ModelAvailability.available?(backend, opts),
      do: {:ok, issue},
      else: {:all_limited, [backend]}
  end

  # The candidate routes for one claim. `agent.priority` is read **fresh per
  # claim and reduced through an ordered chain**, never treated as a fixed
  # literal resolved once at config load: that is what lets a later policy drop
  # or reorder entries per dispatch.
  #
  # Two policies ship here — the backend must be dispatchable, and the route
  # must have its credential — and `:route_policies` is the seam for the rest.
  # The peak-pricing policy (#1456) is the next occupant: it compares entries
  # by cost at the moment of selection, which it can, because a route already
  # resolves to a price identity via `route_price_identity/1`.
  # A policy that returns [] falls through to `{:ok, issue}` (dispatch with no
  # pinned route) rather than stranding the claim.
  defp eligible_routes(opts) do
    Keyword.get(opts, :backends, Config.switch_model_on_ratelimit())
    |> Enum.filter(&(RoutingValue.routing_backend(&1) in configured_backends(opts) and RouteCredentials.usable?(&1, opts)))
    |> apply_route_policies(opts)
    |> apply_peak_pricing_policy(opts)
  end

  defp apply_route_policies(routes, opts) do
    opts
    |> Keyword.get(:route_policies, [])
    |> Enum.reduce(routes, fn policy, acc -> policy.(acc) end)
  end

  # #1456's cost-aware policy, shipping as a default: when `avoid_peak_pricing`
  # is on, drop routes whose billing provider is currently inside a
  # peak-pricing window and fall through to the next `agent.priority` entry.
  #
  # It fails toward NOT rerouting. When the window is unknown (`:unknown`) or
  # the operator's preference cannot be read, the route is kept and
  # `agent.priority` is used exactly as written — a stale window that wrongly
  # believes it is peak would silently move work to another provider, and that
  # is far harder to notice than paying a visible peak rate. And when rejecting
  # the peak-priced routes would leave **no** candidate at all, the original
  # list is kept rather than emptied: an empty list falls through to a
  # bare dispatch with no pinned model (whatever `agent.kind` resolves to),
  # which silently discards the model segment of a sole `deepseek:model`
  # priority entry. See `Aiur.Config.Schema.PricingPolicy`.
  defp apply_peak_pricing_policy(routes, opts) do
    if peak_pricing_avoidance?(opts) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      schedule_for = Keyword.get(opts, :window_schedule_for, &Data.window_schedule/1)
      kept = Enum.reject(routes, &peak_priced_route?(&1, now, schedule_for))

      if kept == [], do: routes, else: kept
    else
      routes
    end
  end

  defp peak_pricing_avoidance?(opts) do
    case Keyword.fetch(opts, :avoid_peak_pricing) do
      {:ok, value} when is_boolean(value) ->
        value

      :error ->
        # Production reads the documented accessor — the single source of
        # truth for the knob (see `Aiur.Config.avoid_peak_pricing?/0`), whose
        # default-on `true` is what an operator with no `pricing_policy` key
        # gets. The reader is injectable so the policy branches are testable
        # without a live config. A config that cannot be read must never move
        # work, so it maps to "do not reroute".
        reader = Keyword.get(opts, :avoid_peak_pricing_reader, &Config.avoid_peak_pricing?/0)
        read_avoid_peak_pricing(reader)
    end
  end

  defp read_avoid_peak_pricing(reader) do
    reader.()
  rescue
    _ -> false
  end

  @doc """
  Whether `avoid_peak_pricing` would drop `route` at `now` because its billing
  provider is inside a peak-pricing window. `false` for routes whose provider
  has no windowed schedule and for unknown windows (fail toward not rerouting).
  """
  @spec peak_priced_route?(String.t(), DateTime.t()) :: boolean()
  def peak_priced_route?(route, now) when is_binary(route) and is_struct(now, DateTime) do
    peak_priced_route?(route, now, &Data.window_schedule/1)
  end

  defp peak_priced_route?(route, now, schedule_for) do
    case schedule_for.(route_price_identity(route).provider) do
      nil -> false
      schedule -> Window.classify(now, schedule) == :peak
    end
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
      provider: backend && ProvidersView.family_for(backend) && String.to_existing_atom(ProvidersView.family_for(backend)),
      model: ModelGrammar.resolve_model(backend, model)
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
      |> Enum.filter(&(&1 in ProvidersView.known_backends()))
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
  @spec model_for(Issue.t(), keyword()) :: String.t() | nil
  # `backend_for/1` already resolves `selected_backend` ahead of everything
  # else, so the model half of the same selected route has to win here too —
  # otherwise dispatch picks `openrouter:anthropic/claude-sonnet-5` and the
  # session starts on whatever the routing table happens to say instead.
  def model_for(issue, opts \\ [])
  def model_for(%Issue{selected_model: model}, _opts) when is_binary(model) and model != "", do: model

  def model_for(%Issue{} = issue, opts) do
    case override_backend(issue, opts) do
      # With no override, the complexity-routing value names the model for the
      # routed backend. A *bare* override names only a backend, so the routing
      # value is the more specific answer and is still deferred to when it
      # targets that same backend: a `model:codex` override still wants the
      # codex routing model, while a `model:deepseek` override must not inherit
      # a codex-shaped model that is invalid for it. A bare override for a
      # backend the routing table never names (an OpenAI-compatible one)
      # therefore yields nil, and `resolve_model/2` supplies the backend default.
      nil ->
        override_model(issue, opts) || routing_model(issue)

      backend ->
        override_model_for(issue, backend, opts)
    end
  end

  # `backend_for/1` resolves `issue.selected_backend` ahead of the override
  # label, so a variant pinned for the overridden backend must never be handed
  # to a different one: `resolve_model/2` forwards a string it does not
  # recognise untouched, so it would reach that CLI verbatim. Nothing sets both
  # today — `select_for_dispatch/2` and the rate-limit fallback only assign a
  # backend when there is no override — so this holds the invariant rather than
  # serving live traffic.
  @spec override_model_for(Issue.t(), backend(), keyword()) :: String.t() | nil
  defp override_model_for(%Issue{selected_backend: selected}, backend, _opts)
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
  defp override_model_for(%Issue{} = issue, backend, opts) do
    case {override_model(issue, opts), routing_backend(issue)} do
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
    case Regex.run(ModelGrammar.model_override_label(), to_string(label)) do
      [_, spec] -> if spec in ModelGrammar.effort_override_values(), do: spec
      _ -> nil
    end
  end

  defp override_model(%Issue{} = issue, opts) do
    case override(issue, opts) do
      {_backend, variant} -> variant
      nil -> nil
    end
  end

  @doc false
  @spec override_backend(Issue.t(), keyword()) :: backend() | nil
  def override_backend(%Issue{} = issue, opts \\ []) do
    case override(issue, opts) do
      {backend, _variant} -> backend
      nil -> nil
    end
  end

  @doc """
  The first `model:` label on an issue that names a model aiur cannot place,
  with why — `{label, cause, backends}` — or `nil` when every model label
  resolves. Causes are `:unknown_name` (no catalogue offers it),
  `:ambiguous` (several do; `backends` names them) and `:catalog_unavailable`
  (no catalogue offers it, but `backends` were never discovered, so it may be
  newer than this build). An unresolved label is ignored for routing; this is
  how the agent runner learns to refresh and to warn.
  """
  @spec model_label_status(Issue.t(), keyword()) :: {String.t(), ModelLabel.cause(), [backend()]} | nil
  def model_label_status(%Issue{} = issue, opts \\ []) do
    known = ProvidersView.dispatchable_backends(Config.agent_backend_configs())

    issue
    |> Issue.label_names()
    |> Enum.find_value(fn label ->
      with [_, spec] <- Regex.run(ModelGrammar.model_override_label(), to_string(label)),
           {:unresolved, cause, backends} <- ModelLabel.resolve(spec, known, label_opts(opts)) do
        {to_string(label), cause, backends}
      else
        _resolved -> nil
      end
    end)
  end

  # First well-formed `model:<backend>[-<variant>]` label naming a known
  # backend, as `{backend, variant | nil}`. Unknown backends are skipped.
  @spec override(Issue.t(), keyword()) :: {backend(), String.t() | nil} | nil
  defp override(%Issue{} = issue, opts) do
    known = ProvidersView.dispatchable_backends(Config.agent_backend_configs())

    issue
    |> Issue.label_names()
    |> Enum.find_value(&match_override(&1, known, opts))
  end

  @spec match_override(term(), [backend()], keyword()) :: {backend(), String.t() | nil} | nil
  defp match_override(label, known, opts) do
    with [_, spec] <- Regex.run(ModelGrammar.model_override_label(), to_string(label)),
         selected when is_tuple(selected) <- ModelLabel.resolve(spec, known, label_opts(opts)) do
      case selected do
        {:backend, backend} -> {backend, nil}
        {:model, backend, variant} -> {backend, variant}
        {:unresolved, _cause, _backends} -> nil
      end
    else
      _not_a_selector -> nil
    end
  end

  # Cache-only: resolving a label must never probe a CLI, because this runs on
  # every orchestrator poll. The agent runner refreshes before it resolves.
  defp label_opts(opts) do
    [
      flags: ModelGrammar.alias_specs() ++ ModelGrammar.effort_override_values(),
      registered: ProvidersView.known_backends(),
      source_for: &ModelDiscovery.source_key/1,
      catalogue: Keyword.get(opts, :catalogue, &ModelDiscovery.catalogue/1),
      expands_family?: Keyword.get(opts, :expands_family?, &ModelDiscovery.cli_catalogue?/1)
    ]
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

  @doc """
  Whether an issue carries a `model:<alias>` label that forces remote
  control ON regardless of the global `agent.remote_control` opt-in
  default. Only the label-only aliases (e.g. `model:remote`) force
  RC; a bare `model:claude-repl` selects the transport but leaves RC to the
  global default.
  """
  @spec remote_control_forced?(Issue.t()) :: boolean()
  def remote_control_forced?(%Issue{} = issue) do
    alias_specs = MapSet.new(ModelGrammar.alias_specs())

    issue
    |> Issue.label_names()
    |> Enum.any?(fn label ->
      case Regex.run(ModelGrammar.model_override_label(), to_string(label)) do
        [_, spec] ->
          MapSet.member?(alias_specs, spec) or
            Enum.any?(alias_specs, &String.starts_with?(spec, &1 <> "-"))

        _ ->
          false
      end
    end)
  end
end

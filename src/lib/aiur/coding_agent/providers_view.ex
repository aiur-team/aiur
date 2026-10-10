defmodule Aiur.CodingAgent.ProvidersView do
  @moduledoc """
  Registry views and provider descriptors for coding-agent backends.

  Read-only projections of `Aiur.CodingAgent.Registry`; the public API is
  `Aiur.CodingAgent`, which delegates here.
  """

  alias Aiur.CodingAgent.Registry

  @type backend :: String.t()

  @doc """
  Registry of supported coding-agent backends. Each entry carries the
  modules, delivery-policy defaults, the model variants worth seeding as
  `model:<backend>-<variant>` override labels, and the backend's valid
  reasoning-`efforts` (used by per-complexity routing). Definitions live in
  provider-owned modules assembled by `Aiur.CodingAgent.Registry`.

  Effort sets are backend-native and verified against the installed CLIs:
  codex maps to `model_reasoning_effort`; the interactive Claude REPL maps
  to `claude --effort`. The headless `claude` backend runs through
  `aiur-claude`, whose current app-server wrapper does not expose an effort
  option, so it intentionally has no effort vocabulary.
  """
  @spec backends() :: %{backend() => Aiur.CodingAgent.Backend.capabilities()}
  def backends, do: Registry.entries()

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
          meter_identity_policy: :account | :host_unverified,
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
            |> Map.put(:meter_identity_policy, Map.get(entry, :meter_identity_policy, :account))
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
end

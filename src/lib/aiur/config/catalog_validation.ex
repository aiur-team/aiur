defmodule Aiur.Config.CatalogValidation do
  @moduledoc false

  import Ecto.Changeset
  alias Aiur.Config.BackendCatalog
  alias Aiur.Config.Schema.AgentValidation

  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(changeset) do
    case BackendCatalog.impl() do
      {:ok, _catalog} -> validate_registered(changeset)
      {:error, reason} -> add_error(changeset, :backend_configs, Atom.to_string(reason), reason: reason)
    end
  end

  defp validate_registered(changeset) do
    changeset
    |> AgentValidation.validate_backend_configs()
    |> update_change(:max_concurrent_agents_by_state, &AgentValidation.normalize_state_limits/1)
    |> AgentValidation.validate_state_limits(:max_concurrent_agents_by_state)
    |> update_change(:routing, &AgentValidation.normalize_agent_routing/1)
    |> AgentValidation.validate_agent_routing(:routing)
    |> AgentValidation.split_routing_candidates()
    |> AgentValidation.validate_dispatch_selections()
    |> AgentValidation.validate_agent_priority(:priority)
    |> validate_change(:switch_model_on_ratelimit, &validate_switch/2)
    |> validate_change(:rate_limit_primary, &validate_primary/2)
    |> AgentValidation.validate_rate_limit_fallback()
  end

  defp validate_switch(:switch_model_on_ratelimit, backends) do
    known = BackendCatalog.known_backends()

    cond do
      backends != Enum.uniq(backends) -> [switch_model_on_ratelimit: "must not contain duplicate backends"]
      Enum.all?(backends, &(&1 in known)) -> []
      true -> [switch_model_on_ratelimit: "contains an unknown backend; known backends: #{inspect(known)}"]
    end
  end

  defp validate_primary(:rate_limit_primary, backend) do
    known = BackendCatalog.known_backends()

    if backend in known,
      do: [],
      else: [rate_limit_primary: "must be a registered backend; known backends: #{inspect(known)}"]
  end
end

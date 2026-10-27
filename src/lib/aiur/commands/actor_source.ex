defmodule Aiur.Commands.ActorSource do
  @moduledoc "Closed entry-point attribution vocabulary. Source never grants authority."

  @sources [:rpc, :dashboard_session, :basic_auth, :device, :streamdeck, :cli, :relay_cli, :executor_cli, :supervisor_api]

  @spec from_opts(keyword()) :: atom()
  def from_opts(opts) do
    case Keyword.get(opts, :actor_source) do
      source when source in @sources -> source
      _other -> :rpc
    end
  end

  @spec preserve(map(), map()) :: map()
  def preserve(normalized, raw) do
    source = Map.get(raw, :source, Map.get(raw, "source"))

    case Enum.find(@sources, &(source == &1 or source == Atom.to_string(&1))) do
      nil -> normalized
      source -> Map.put(normalized, :source, source)
    end
  end

  @spec to_json_safe(map()) :: map()
  def to_json_safe(actor) do
    json = %{"kind" => Atom.to_string(actor.kind), "id" => actor.id}

    case Map.get(actor, :source) do
      source when source in @sources -> Map.put(json, "source", Atom.to_string(source))
      _other -> json
    end
  end
end

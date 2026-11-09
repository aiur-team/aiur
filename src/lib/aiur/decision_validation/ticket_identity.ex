defmodule Aiur.DecisionValidation.TicketIdentity do
  @moduledoc false

  @fields [:version, :status, :kind, :owner, :repository, :provider_id, :database_id, :identifier, :reason]
  @enum_values %{
    status: [:joinable, :unjoinable],
    kind: [:github],
    reason: [
      :legacy,
      :missing_configured_repository,
      :invalid_configured_repository,
      :repository_mismatch,
      :missing_provider_identity,
      :invalid_provider_identity,
      :invalid_display_identifier
    ]
  }

  @spec put(map(), term()) :: map()
  def put(ticket, %Aiur.TrackerIdentity{} = identity) do
    if Aiur.TrackerIdentity.joinable?(identity), do: Map.put(ticket, :tracker_identity, identity), else: ticket
  end

  def put(ticket, identity) when is_map(identity) do
    values = Map.new(@fields, fn field -> {field, identity_value(identity, field)} end)
    put(ticket, struct(Aiur.TrackerIdentity, values))
  end

  def put(ticket, _identity), do: ticket

  defp identity_value(identity, field) do
    value = Map.get(identity, field, Map.get(identity, Atom.to_string(field)))

    case {value, Map.get(@enum_values, field)} do
      {value, allowed} when is_binary(value) and is_list(allowed) ->
        if value in Enum.map(allowed, &Atom.to_string/1), do: String.to_existing_atom(value), else: value

      _other ->
        value
    end
  end
end

defmodule Aiur.CurrentRunMembership.Projection do
  @moduledoc false

  import Kernel, except: [apply: 2]

  alias Aiur.CurrentRunMembership.Event
  alias Aiur.TrackerIdentity

  @checkpoint_member_keys ~w(first_observed_at last_event)

  @enforce_keys [:run_id]
  defstruct run_id: nil, members: %{}, generation: 0

  defmodule Member do
    @moduledoc false

    @enforce_keys [
      :identity,
      :lifecycle,
      :terminal?,
      :first_observed_at,
      :last_observed_at,
      :last_checksum,
      :last_event
    ]
    defstruct [:identity, :lifecycle, :terminal?, :first_observed_at, :last_observed_at, :last_checksum, :last_event]
  end

  @type member :: %Member{
          identity: TrackerIdentity.t(),
          lifecycle: Event.lifecycle(),
          terminal?: boolean(),
          first_observed_at: DateTime.t(),
          last_observed_at: DateTime.t(),
          last_checksum: String.t(),
          last_event: Event.t()
        }

  @type t :: %__MODULE__{run_id: String.t(), members: %{tuple() => member()}, generation: non_neg_integer()}

  @spec new(String.t()) :: t()
  def new(run_id) when is_binary(run_id) and byte_size(run_id) > 0, do: %__MODULE__{run_id: run_id}

  @spec apply(t(), Event.t()) :: {:accepted, t()} | {:ignored, atom(), t()}
  def apply(%__MODULE__{} = state, %Event{} = event) do
    cond do
      event.run_id != state.run_id ->
        {:ignored, :different_run, state}

      not Event.valid?(event) ->
        {:ignored, :invalid_event, state}

      true ->
        apply_event(state, event, identity_key(event.identity))
    end
  end

  @spec replay(String.t(), [Event.t()]) :: {:ok, t()} | {:error, atom()}
  def replay(run_id, events) when is_binary(run_id) and is_list(events) do
    state = new(run_id)

    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case apply(state, event) do
        {:accepted, state} -> {:cont, {:ok, state}}
        {:ignored, :different_run, _state} -> {:halt, {:error, :different_run}}
        {:ignored, :invalid_event, _state} -> {:halt, {:error, :invalid_event}}
        {:ignored, _reason, state} -> {:cont, {:ok, state}}
      end
    end)
  end

  @spec member(t(), TrackerIdentity.t()) :: member() | nil
  def member(%__MODULE__{} = state, %TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity), do: Map.get(state.members, identity_key(identity)), else: nil
  end

  @spec members(t()) :: [member()]
  def members(%__MODULE__{} = state) do
    state.members
    |> Enum.sort_by(fn {key, _member} -> key end)
    |> Enum.map(fn {_key, member} -> member end)
  end

  @spec checkpoint(t()) :: map()
  def checkpoint(%__MODULE__{} = state) do
    %{
      "run_id" => state.run_id,
      "generation" => state.generation,
      "members" =>
        Enum.map(members(state), fn member ->
          %{
            "first_observed_at" => DateTime.to_iso8601(member.first_observed_at),
            "last_event" => Event.to_record(member.last_event)
          }
        end)
    }
  end

  @spec restore_checkpoint(String.t(), non_neg_integer(), [map()]) :: {:ok, t()} | {:error, atom()}
  def restore_checkpoint(run_id, generation, entries)
      when is_binary(run_id) and is_integer(generation) and generation >= 0 and is_list(entries) do
    with {:ok, state} <- restore_entries(run_id, entries),
         true <- generation >= map_size(state.members) do
      {:ok, %{state | generation: generation}}
    else
      false -> {:error, :invalid_generation}
      {:error, reason} -> {:error, reason}
    end
  end

  def restore_checkpoint(_run_id, _generation, _entries), do: {:error, :invalid_checkpoint}

  @spec identity_key(TrackerIdentity.t()) :: {String.t(), String.t(), String.t()}
  def identity_key(%TrackerIdentity{owner: owner, repository: repository, provider_id: provider_id}) do
    {String.downcase(owner), String.downcase(repository), provider_id}
  end

  defp apply_event(state, event, key) do
    case Map.get(state.members, key) do
      nil ->
        member = %Member{
          identity: event.identity,
          lifecycle: event.lifecycle,
          terminal?: Event.terminal?(event),
          first_observed_at: event.observed_at,
          last_observed_at: event.observed_at,
          last_checksum: event.checksum,
          last_event: event
        }

        {:accepted, %{state | members: Map.put(state.members, key, member), generation: state.generation + 1}}

      %Member{last_checksum: checksum} when checksum == event.checksum ->
        {:ignored, :duplicate, state}

      %Member{lifecycle: lifecycle} when lifecycle == event.lifecycle ->
        {:ignored, :duplicate, state}

      %Member{terminal?: true} ->
        {:ignored, :terminal, state}

      %Member{last_observed_at: last_observed_at} = member ->
        if DateTime.compare(event.observed_at, last_observed_at) == :gt do
          updated = %Member{
            member
            | identity: event.identity,
              lifecycle: event.lifecycle,
              terminal?: Event.terminal?(event),
              last_observed_at: event.observed_at,
              last_checksum: event.checksum,
              last_event: event
          }

          {:accepted, %{state | members: Map.put(state.members, key, updated), generation: state.generation + 1}}
        else
          {:ignored, :out_of_order, state}
        end
    end
  end

  defp restore_entries(run_id, entries) do
    Enum.reduce_while(entries, {:ok, new(run_id)}, fn
      entry, {:ok, state} when is_map(entry) ->
        with @checkpoint_member_keys <- entry |> Map.keys() |> Enum.sort(),
             %{"first_observed_at" => first_observed_at, "last_event" => event_record} <- entry,
             {:ok, first_observed_at} <- parse_timestamp(first_observed_at),
             {:ok, event} <- Event.from_record(event_record),
             true <- event.run_id == run_id,
             true <- DateTime.compare(first_observed_at, event.observed_at) in [:lt, :eq],
             {:accepted, restored} <- apply(state, event) do
          key = identity_key(event.identity)
          member = Map.fetch!(restored.members, key)
          member = %{member | first_observed_at: first_observed_at}
          {:cont, {:ok, %{restored | members: Map.put(restored.members, key, member)}}}
        else
          false -> {:halt, {:error, :invalid_checkpoint}}
          {:ignored, _reason, _state} -> {:halt, {:error, :invalid_checkpoint}}
          {:error, _reason} -> {:halt, {:error, :invalid_checkpoint}}
          _ -> {:halt, {:error, :invalid_checkpoint}}
        end

      _entry, {:ok, _state} ->
        {:halt, {:error, :invalid_checkpoint}}
    end)
  end

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, 0} -> {:ok, timestamp}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp parse_timestamp(_value), do: {:error, :invalid_timestamp}
end

defmodule Aiur.BuildOrder.History.Row do
  @moduledoc "Validated history facts; unknown and known absence remain distinct."
  alias Aiur.BuildOrder.History.{Codec, Merge}
  alias Aiur.BuildOrder.Lifecycle

  @sources ~w(backfill resource_store webhook poll write resync open_listing recent_merge telemetry catch_up derive)a
  @dates ~w(created_at updated_at closed_at last_closed_at close_observed_at reopened_at merged_at in_progress_at dispatched_at start end)a
  @derived ~w(start start_source end end_source clamped)a
  @fields ~w(title lifecycle created_at node_id updated_at closed_at last_closed_at close_observed_at reopened_at merged_at pr_number labels labels_complete label_events sub_issues_added timeline_complete parent parent_version blocked_by blocked_by_complete blocked_by_version in_progress_at dispatched_at start start_source end end_source clamped agent_model agent_effort)a
  defstruct [number: :unknown, observed_at: :unknown, lifecycle: %Lifecycle{}, clamped: false, sources: []] ++
              Enum.map(@fields -- [:lifecycle, :clamped], &{&1, :unknown})

  @type t :: %__MODULE__{}
  @type event :: %{number: pos_integer(), observed_at: DateTime.t(), source: atom(), fields: map()}

  @spec sources() :: [atom()]
  def sources, do: @sources
  @spec fields() :: [atom()]
  def fields, do: @fields
  @spec dates() :: [atom()]
  def dates, do: @dates

  @spec validate_event(term()) :: {:ok, event()} | {:error, term()}
  def validate_event(%{number: n, observed_at: %DateTime{}, source: source, fields: fields} = event)
      when is_integer(n) and n > 0 and source in @sources and is_map(fields) do
    case Enum.find(fields, fn {key, value} -> key not in @fields or not valid?(key, value) or (key in @derived and source != :derive) end) do
      nil -> {:ok, event}
      {key, _} -> {:error, {:invalid_field, key}}
    end
  end

  def validate_event(_event), do: {:error, :invalid_shape}

  @spec valid?(atom(), term()) :: boolean()
  def valid?(key, :unknown), do: key in @fields and key not in [:clamped, :lifecycle]
  def valid?(key, :none), do: key in ~w(closed_at last_closed_at close_observed_at reopened_at merged_at pr_number parent in_progress_at dispatched_at end agent_model agent_effort)a
  def valid?(key, %DateTime{}), do: key in @dates or key == :observed_at
  def valid?(:number, n), do: is_integer(n) and n > 0
  def valid?(:pr_number, n), do: is_integer(n) and n > 0
  def valid?(key, value) when key in [:title, :node_id, :agent_model, :agent_effort], do: string?(value)
  def valid?(key, value) when key in [:parent_version, :blocked_by_version], do: string?(value) or (is_integer(value) and value >= 0)
  def valid?(key, value) when key in [:labels_complete, :timeline_complete, :blocked_by_complete, :clamped], do: is_boolean(value)
  def valid?(:lifecycle, %Lifecycle{state: state, state_reason: :unknown}) when state in [:unknown, :closed], do: true
  def valid?(:lifecycle, value), do: Lifecycle.valid?(value)
  def valid?(:parent, value), do: ref?(value)
  def valid?(:blocked_by, value), do: list?(value, &ref?/1)
  def valid?(:labels, value), do: list?(value, &string?/1)
  def valid?(:label_events, value), do: list?(value, &label_event?/1)
  def valid?(:sub_issues_added, value), do: list?(value, &sub_issue?/1)
  def valid?(:sources, value), do: list?(value, &(&1 in @sources))
  def valid?(:start_source, value), do: value in [:label, :dispatch]
  def valid?(:end_source, value), do: value in [:merged, :closed]
  def valid?(_key, _value), do: false

  @spec merge(t() | nil, event()) :: {:changed, t()} | :unchanged
  def merge(row, event), do: Merge.merge(row, event)
  @spec to_json(t()) :: map()
  def to_json(row), do: Codec.encode(row)
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(value), do: Codec.decode(value)

  defp string?(value), do: is_binary(value) and String.valid?(value)
  defp list?(value, fun), do: is_list(value) and Enum.all?(value, fun)

  defp ref?(%{owner: owner, repository: repo, number: n} = ref),
    do: map_size(ref) == 3 and string?(owner) and owner != "" and string?(repo) and repo != "" and is_integer(n) and n > 0

  defp ref?(_ref), do: false

  defp label_event?(%{label: label, action: action, at: %DateTime{}, actor: actor} = event),
    do: map_size(event) == 4 and string?(label) and action in [:labeled, :unlabeled] and (actor == :unknown or string?(actor))

  defp label_event?(_event), do: false
  defp sub_issue?(%{ref: ref, at: %DateTime{}} = event), do: map_size(event) == 2 and ref?(ref)
  defp sub_issue?(_event), do: false
end

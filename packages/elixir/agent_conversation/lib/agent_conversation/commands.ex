defmodule AgentConversation.Commands do
  @moduledoc """
  Pending Commands inside a transcript.

  A Command row is host data: the component renders it inline at the transcript
  position the host reports, or in a pinned block when the position is unknown.
  Answering always goes through the host's own answering boundary
  (`AgentConversation.Host.Transport.answer_command/4`), so the embed never grows
  a second answer path.

  The one thing the component owns is what a reader sees when two principals
  answer the same Command: the losing answer is not hidden, it is replaced by a
  conflict notice naming the answer that won.
  """

  @statuses [:pending, :answered]

  @type row :: %{
          id: String.t(),
          question: String.t(),
          status: atom(),
          options: [map()],
          position: pos_integer() | nil,
          conflict: String.t() | nil
        }

  @doc "Every Command status the component understands."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  Normalizes a Command row from a transport.

  Accepts `:id` or `:decision_id` for identity and `:position` or `:pos` for the
  transcript position, which is what lets an Aiur decision row and a plain host
  row share one renderer.
  """
  @spec normalize(map()) :: row()
  def normalize(row) when is_map(row) do
    %{
      id: to_string(get(row, :id) || get(row, :decision_id) || ""),
      question: to_string(get(row, :question) || get(row, :title) || "Pending Command"),
      status: if(get(row, :answer) || get(row, :answered_at), do: :answered, else: :pending),
      options: List.wrap(get(row, :options) || []),
      position: get(row, :position) || get(row, :pos),
      conflict: get(row, :conflict_summary) || get(row, :conflict)
    }
  end

  def normalize(_row),
    do: %{id: "", question: "Pending Command", status: :pending, options: [], position: nil, conflict: nil}

  @doc "Normalizes a list of Command rows, dropping ones without an id."
  @spec normalize_all(term()) :: [row()]
  def normalize_all(rows) when is_list(rows), do: rows |> Enum.map(&normalize/1) |> Enum.reject(&(&1.id == ""))
  def normalize_all(_rows), do: []

  @doc """
  Maps each Command id to where the component renders it.

  A Command whose position is loaded as an anchor becomes inline; everything else
  is pinned above the transcript so a question is never lost.
  """
  @spec slots([row()], [pos_integer()]) :: %{optional(String.t()) => {:at_pos, pos_integer()} | :pinned_top}
  def slots(rows, positions) do
    positions = MapSet.new(positions)

    Map.new(rows, fn row ->
      if is_integer(row.position) and MapSet.member?(positions, row.position) do
        {row.id, {:at_pos, row.position}}
      else
        {row.id, :pinned_top}
      end
    end)
  end

  @doc "The rows the component renders in one slot."
  @spec at([row()], map(), term()) :: [row()]
  def at(rows, slots, slot), do: Enum.filter(rows, &(Map.get(slots, &1.id) == slot))

  @doc "Whether this principal may answer the row."
  @spec answerable?(row(), boolean()) :: boolean()
  def answerable?(%{status: :pending}, writable), do: writable == true
  def answerable?(_row, _writable), do: false

  @doc """
  Records an answer outcome against a Command id.

  `{:ok, receipt}` marks the row answered. `{:error, {:conflict, summary}}` keeps
  the row visible and stores the summary so the conflict notice can name the
  winning answer instead of pretending the answer landed.
  """
  @spec record(map(), String.t(), {:ok, map()} | {:error, term()}) :: map()
  def record(outcomes, id, {:ok, receipt}) when is_map(outcomes) do
    Map.put(outcomes, id, %{outcome: :answered, receipt: receipt})
  end

  def record(outcomes, id, {:error, {:conflict, summary}}) when is_map(outcomes) do
    Map.put(outcomes, id, %{outcome: :already_answered, winner: summary})
  end

  def record(outcomes, id, {:error, reason}) when is_map(outcomes),
    do: Map.put(outcomes, id, %{outcome: :failed, reason: reason})

  def record(outcomes, _id, _result), do: outcomes

  @doc "The notice a conflicting answer shows, or nil when there is no conflict."
  @spec notice(map(), String.t()) :: String.t() | nil
  def notice(outcomes, id) do
    case Map.get(outcomes, id) do
      %{outcome: :already_answered} -> "Another answer landed first; this Command is now closed."
      %{outcome: :failed, reason: reason} -> "The answer was not delivered (#{reason})."
      _outcome -> nil
    end
  end

  defp get(row, key), do: Map.get(row, key) || Map.get(row, Atom.to_string(key))
end

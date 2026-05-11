defmodule SymphonyElixir.TUI.State do
  @moduledoc false

  defstruct [
    :snapshot,
    :snapshot_source,
    :refresh_ms,
    selected_index: nil
  ]

  @type t :: %__MODULE__{
          snapshot: term(),
          snapshot_source: (-> term()),
          refresh_ms: pos_integer(),
          selected_index: non_neg_integer() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    snapshot_source = Keyword.fetch!(opts, :snapshot_source)
    refresh_ms = Keyword.fetch!(opts, :refresh_ms)
    snapshot = snapshot_source.()

    %__MODULE__{
      snapshot: snapshot,
      snapshot_source: snapshot_source,
      refresh_ms: refresh_ms,
      selected_index: initial_selected_index(snapshot)
    }
  end

  @spec refresh(t()) :: t()
  def refresh(%__MODULE__{} = state) do
    snapshot = state.snapshot_source.()

    %{state | snapshot: snapshot}
    |> clamp_selection()
  end

  @spec select_next(t()) :: t()
  def select_next(%__MODULE__{} = state), do: move_selection(state, 1)

  @spec select_previous(t()) :: t()
  def select_previous(%__MODULE__{} = state), do: move_selection(state, -1)

  defp move_selection(%__MODULE__{} = state, _delta) when state.selected_index == nil do
    %{state | selected_index: initial_selected_index(state.snapshot)}
  end

  defp move_selection(%__MODULE__{} = state, delta) do
    case running_count(state.snapshot) do
      0 ->
        %{state | selected_index: nil}

      count ->
        next_index =
          state.selected_index
          |> Kernel.+(delta)
          |> max(0)
          |> min(count - 1)

        %{state | selected_index: next_index}
    end
  end

  defp clamp_selection(%__MODULE__{} = state) do
    case running_count(state.snapshot) do
      0 ->
        %{state | selected_index: nil}

      _count when state.selected_index == nil ->
        %{state | selected_index: 0}

      count ->
        %{state | selected_index: min(state.selected_index, count - 1)}
    end
  end

  defp initial_selected_index(snapshot) do
    if running_count(snapshot) > 0, do: 0, else: nil
  end

  defp running_count({:ok, %{running: running}}) when is_list(running), do: length(running)
  defp running_count(_snapshot), do: 0
end

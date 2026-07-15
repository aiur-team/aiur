defmodule Aiur.BuildOrder.Activity do
  @moduledoc "Aiur execution evidence kept separate from GitHub lifecycle facts."

  @type progress :: 0..100 | :unknown
  @type t :: %__MODULE__{
          execution_state: atom() | :unknown,
          agent_stage: atom() | :unknown,
          progress: progress()
        }

  defstruct execution_state: :unknown, agent_stage: :unknown, progress: :unknown

  @spec new(term(), term(), term()) :: t()
  def new(execution_state, agent_stage, progress) do
    %__MODULE__{
      execution_state: atom_or_unknown(execution_state),
      agent_stage: atom_or_unknown(agent_stage),
      progress: progress(progress)
    }
  end

  defp atom_or_unknown(value) when is_atom(value) and not is_nil(value), do: value
  defp atom_or_unknown(_value), do: :unknown
  defp progress(value) when is_integer(value) and value in 0..100, do: value
  defp progress(_value), do: :unknown
end

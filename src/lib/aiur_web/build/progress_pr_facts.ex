defmodule AiurWeb.Build.ProgressPRFacts do
  @moduledoc false

  alias Aiur.StartTrigger.ProgressStore

  @spec read(term(), keyword()) :: %{optional(String.t()) => map()}
  def read(source, opts \\ [])

  def read(%{snapshot: %{rows: rows}}, opts) when is_list(rows), do: read_rows(rows, opts)
  def read(rows, opts) when is_list(rows), do: read_rows(rows, opts)
  def read(_source, _opts), do: %{}

  defp read_rows(rows, opts) do
    lookup = Keyword.get(opts, :lookup) || (&ProgressStore.lookup/1)

    Enum.reduce(rows, %{}, fn row, facts ->
      with %{identifier: id} when is_binary(id) <- Map.get(row, :identity),
           %{pr_number: number, stage: stage, closed_unmerged?: false} <- lookup.(id),
           true <- is_integer(number) and number > 0 and stage != :pr_merged do
        Map.put(facts, id, %{num: number, state: "open", ci: if(stage, do: to_string(stage))})
      else
        _ -> facts
      end
    end)
  end
end

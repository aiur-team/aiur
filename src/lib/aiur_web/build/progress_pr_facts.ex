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
           pr_fact <- lookup.(id),
           true <- ProgressStore.open_pr?(pr_fact) do
        Map.put(facts, id, %{num: pr_fact.pr_number, state: "open", ci: if(pr_fact.stage, do: to_string(pr_fact.stage))})
      else
        _ -> facts
      end
    end)
  end
end

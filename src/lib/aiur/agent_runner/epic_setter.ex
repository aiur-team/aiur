defmodule Aiur.AgentRunner.EpicSetter do
  @moduledoc false
  alias Aiur.BuildOrder.EpicOverrides
  alias Aiur.BuildOrder.EpicOverrides.Override

  @spec set(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def set(issue, args, opts \\ []) do
    with {:ok, number} <- bound_number(issue) do
      actor = "agent:#{number}"
      provenance = %{actor: actor, source: if(args.backfill, do: "backfill-agent", else: actor)}
      ids = args.ids || [number]
      if args.clear, do: EpicOverrides.clear(ids, provenance, opts), else: EpicOverrides.set(args.epic, ids, provenance, opts)
    end
  end

  defp bound_number(issue) do
    case Override.number(Map.get(issue, :number) || Map.get(issue, :identifier)) do
      {:ok, n} -> {:ok, n}
      _ -> {:error, :no_issue_number}
    end
  end
end

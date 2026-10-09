defmodule Aiur.BuildOrder.Features.RootImportWrites do
  @moduledoc false
  @meta [source: "import:build-order", actor: "import"]

  @spec apply(map(), (atom(), list() -> term())) :: :ok | {:error, term()}
  def apply(plan, writer) do
    operations = Enum.flat_map([:creates, :updates, :new_epics, :moves, :removes, :adds, :also, :also_removes], fn kind -> Enum.map(plan[kind], &operation(kind, &1)) end)

    Enum.reduce_while(operations, :ok, fn {op, args}, :ok ->
      case writer.(op, args) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp operation(:creates, %{slug: slug} = attrs), do: {:create, [slug, Map.delete(attrs, :slug), @meta]}
  defp operation(:updates, %{slug: slug} = attrs), do: {:update_feature, [slug, Map.delete(attrs, :slug), @meta]}
  defp operation(:new_epics, {slug, epic}), do: {:add_epic, [slug, epic, @meta]}
  defp operation(:moves, {slug, ns, epic, at}), do: {:add, [slug, ns, @meta ++ [epic: epic, at: at, move: true]]}
  defp operation(:adds, {slug, ns, epic, at}), do: {:add, [slug, ns, @meta ++ [epic: epic, at: at]]}
  defp operation(:removes, {slug, ns}), do: {:remove, [slug, ns, @meta]}
  defp operation(:also, {slug, ns}), do: {:also, [slug, ns, @meta]}
  defp operation(:also_removes, {slug, ns}), do: {:also, [slug, ns, @meta ++ [remove: true]]}
end

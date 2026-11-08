defmodule AiurWeb.Build.Index.Drain do
  @moduledoc "Coalesces queued refresh signals so the build index mailbox cannot grow while a read or assemble is slow (#7816)."

  @doc "Dirty parts for `tag`, merged with those of every refresh signal already queued (consumed)."
  @spec keys(%{atom() => [atom()]}, atom()) :: [atom()]
  def keys(signals, tag), do: collect(signals, Map.fetch!(signals, tag))

  defp collect(signals, acc) do
    receive do
      {tag, _payload} when is_map_key(signals, tag) -> collect(signals, signals[tag] ++ acc)
      :fleet_changed -> collect(signals, [:capacity | acc])
    after
      0 -> Enum.uniq(acc)
    end
  end
end

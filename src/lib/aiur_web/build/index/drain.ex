defmodule AiurWeb.Build.Index.Drain do
  @moduledoc "Coalesces queued refresh signals so the build index mailbox cannot grow while a read or assemble is slow (#7816)."

  @doc "Dirty parts for `tag`, merged with those of every refresh signal already queued (consumed)."
  @spec keys(%{atom() => [atom()]}, atom()) :: [atom()]
  def keys(signals, tag), do: collect(signals, signals[:poll_state_changed], Map.fetch!(signals, tag))

  # `:fleet_changed` is the bare form of `:poll_state_changed`; its parts come from the same map entry.
  defp collect(signals, fleet, acc) do
    receive do
      {tag, _payload} when is_map_key(signals, tag) -> collect(signals, fleet, signals[tag] ++ acc)
      :fleet_changed -> collect(signals, fleet, fleet ++ acc)
    after
      0 -> Enum.uniq(acc)
    end
  end
end

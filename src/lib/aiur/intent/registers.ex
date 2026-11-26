defmodule Aiur.Intent.Registers do
  @moduledoc """
  The one register MPG-406 reads and writes: `(fleet, "fleet", pause)`. The value is only ever the
  `Reconciler.fold/2` result (any paused slot pauses; a human unpause clears every slot). A daemon
  never calls `write_fleet_pause/2`; only `aiur pause|resume --all-gateways` does.
  """

  alias Aiur.Gateway.Identity
  alias Aiur.Intent.{Reconciler, Store, Sync, Writer}

  @key {"fleet", "fleet", "pause"}

  @type pause :: {:paused, String.t(), DateTime.t(), String.t()} | :clear | :never_synced

  @doc "Folded fleet pause from the local change cache. `:never_synced` when no fleet change was ever seen."
  @spec fleet_pause(keyword()) :: pause()
  def fleet_pause(opts \\ []) do
    store = Keyword.get(opts, :store, Store)
    changes = if GenServer.whereis(store), do: Store.changes(store), else: []
    now = Keyword.get_lazy(opts, :now_ms, &Sync.os_now/0)
    regs = Reconciler.fold(changes, now_ms: now, own_gateway: own_gateway(opts))

    case regs do
      %{@key => %{effective: true, winning_change_id: id}} -> paused(Enum.find(changes, &(&1.change_id == id)))
      %{@key => _} -> :clear
      _ -> :never_synced
    end
  end

  @doc "Authors a `fleet.pause` change. `opts`: `as` (an Executor id; absent means the human slot), `reason`."
  @spec write_fleet_pause(boolean(), keyword()) :: {:ok, Aiur.Intent.Change.t()} | {:error, atom()}
  def write_fleet_pause(value, opts \\ []) when is_boolean(value) do
    as = Keyword.get(opts, :as)

    attrs = %{
      slot: if(as, do: "executor", else: "human"),
      author_id: as || "cli",
      entity_kind: "fleet",
      entity_key: "fleet",
      field: "pause",
      value_json: value,
      reason: Keyword.get(opts, :reason)
    }

    Writer.write(attrs, Keyword.take(opts, [:hlc, :store, :sync]))
  end

  defp paused(%{change_id: id, hlc_wall_ms: wall, origin_gateway: gateway, author_id: author}),
    do: {:paused, id, DateTime.from_unix!(wall, :millisecond), author || gateway}

  defp own_gateway(opts) do
    Keyword.get_lazy(opts, :own_gateway, fn -> Identity.current().gateway_id end)
  end
end

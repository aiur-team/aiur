defmodule AiurWeb.Build.NavCount do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2]
  alias AiurWeb.Build.Payload

  @type t :: %{ids: %{optional(term()) => true}, known?: boolean(), ready?: boolean()}

  @spec unknown() :: t()
  def unknown, do: %{ids: %{}, known?: false, ready?: false}

  @spec from_snapshot(map()) :: t()
  def from_snapshot(payload) do
    payload = Payload.scrub(payload)
    rows = get_in(payload, ["sections", "now"]) || []
    %{ids: rows |> Enum.filter(&active?/1) |> Map.new(&{&1["id"], true}), known?: known?(payload["sources"]), ready?: true}
  end

  @spec apply(t(), map()) :: t()
  def apply(state, changes) do
    changes = Payload.scrub(changes)

    if changes["resync"] == true do
      unknown()
    else
      ids = Enum.reduce(changes["upsert"] || [], state.ids, &put_row/2)
      ids = Enum.reduce(changes["remove"] || [], ids, &Map.delete(&2, &1))
      sources = get_in(changes, ["set", "sources"])
      %{state | ids: ids, known?: if(is_map(sources), do: known?(sources), else: state.known?)}
    end
  end

  @spec count(t()) :: non_neg_integer() | nil
  def count(%{known?: true, ready?: true, ids: ids}), do: map_size(ids)
  def count(_state), do: nil

  @spec put(Phoenix.LiveView.Socket.t(), t()) :: Phoenix.LiveView.Socket.t()
  def put(socket, state) do
    counts = Map.delete(socket.assigns[:nav_counts] || %{}, :build)

    counts =
      case count(state) do
        nil -> counts
        value -> Map.put(counts, :build, value)
      end

    assign(socket, build_nav_count: state, nav_counts: counts)
  end

  defp active?(%{"sec" => "now", "agent" => %{"state" => "active"}}), do: true
  defp active?(_row), do: false
  defp put_row(row, ids), do: if(active?(row), do: Map.put(ids, row["id"], true), else: Map.delete(ids, row["id"]))
  defp known?(%{"agents" => %{"state" => state}}), do: state in ["ok", "stale"]
  defp known?(_sources), do: false
end

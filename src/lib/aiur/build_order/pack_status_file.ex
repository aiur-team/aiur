defmodule Aiur.BuildOrder.PackStatusFile do
  @moduledoc "Reads, merges and atomically replaces the daemon-owned `status.json` projection."

  require Logger

  alias Aiur.BuildOrder.PackPaths
  alias Aiur.Fs

  @doc false
  @spec write_status(Path.t(), map(), map()) :: {:ok, boolean()} | {:error, term()}
  def write_status(pack_path, lifecycles, state) do
    path = PackPaths.status_path(pack_path)
    observed_at = DateTime.to_iso8601(state.now_fun.())

    case read_status(path) do
      {:ok, existing} ->
        merge_status(path, existing, lifecycles, observed_at)

      {:error, reason} = error ->
        Logger.warning("aiur_build_order_pack_status phase=read_failed path=#{path} reason=#{inspect(reason)}")
        error
    end
  end

  defp merge_status(path, existing, lifecycles, observed_at) do
    existing_members = existing |> Map.get("members", %{}) |> then(&if(is_map(&1), do: &1, else: %{}))

    members =
      Map.merge(
        existing_members,
        Map.new(lifecycles, fn {number, lifecycle} ->
          {number, %{"lifecycle" => lifecycle, "observed_at" => observed_at}}
        end)
      )

    # `observed_at` alone would rewrite the projection every cycle; only a
    # changed lifecycle is worth a write.
    if lifecycle_map(existing_members) == lifecycle_map(members) do
      {:ok, false}
    else
      with {:ok, body} <- Jason.encode(Map.put(existing, "members", members), pretty: true),
           :ok <- atomic_write(path, body <> "\n") do
        {:ok, true}
      end
    end
  end

  defp lifecycle_map(members), do: Map.new(members, fn {number, member} -> {number, member_lifecycle(member)} end)

  defp member_lifecycle(%{"lifecycle" => lifecycle}), do: lifecycle
  defp member_lifecycle(%{"state" => state}), do: state
  defp member_lifecycle(lifecycle) when is_binary(lifecycle), do: lifecycle
  defp member_lifecycle(_member), do: nil

  defp read_status(path) do
    case File.read(path) do
      {:ok, body} -> decode_status(body)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:status_read_failed, reason}}
    end
  end

  defp decode_status(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :invalid_status}
    end
  end

  # A torn status.json would reset completion to unknown, so the projection is
  # replaced by rename rather than written in place.
  defp atomic_write(path, body) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- Fs.atomic_write(path, body, fsync: true) do
      :ok
    else
      error ->
        Logger.warning("aiur_build_order_pack_status phase=write_failed reason=#{inspect(error)}")
        error
    end
  end
end

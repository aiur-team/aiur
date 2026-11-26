defmodule Aiur.Ownership.PeerState do
  @moduledoc """
  Local delegation state, one atomic file `ownership/delegation.json` under the Aiur home.

  `peers` caches each peer's last project list (`gateway_id`, `label`, `daemon_key`, `projects`, `observed_at`);
  `delegations` records the transfers this gateway wrote (the delegator is not in the ownership ref).
  A missing or corrupt file reads as empty. At most 500 delegations are kept, oldest dropped.
  """

  @cap 500

  @spec path() :: Path.t()
  def path do
    dir = Application.get_env(:aiur, :ownership_state_dir, Path.join([System.get_env("HOME") || Path.expand("~"), ".aiur", "ownership"]))
    Path.join(dir, "delegation.json")
  end

  @doc "Peer by label, gateway id or registry name (case-insensitive), with `observed_at` parsed."
  @spec peer(String.t()) :: map() | nil
  def peer(name) do
    wanted = String.downcase(name)

    Enum.find_value(read()["peers"], fn {id, p} ->
      if wanted in [String.downcase(id), String.downcase(p["label"] || "")], do: peer_map(id, p)
    end)
  end

  @spec put_peer(String.t(), map()) :: :ok | {:error, term()}
  def put_peer(gateway_id, %{} = fields), do: update(&put_in(&1, ["peers", gateway_id], stringify(fields)))

  @spec add_delegation(map()) :: :ok | {:error, term()}
  def add_delegation(%{repo: repo, ticket: ticket} = d) do
    update(fn state ->
      kept = Enum.reject(state["delegations"], &(&1["repo"] == repo and &1["ticket"] == ticket))
      %{state | "delegations" => Enum.take([stringify(d) | kept], @cap)}
    end)
  end

  @spec delegation(String.t(), String.t()) :: %{epoch: integer(), gateway_id: String.t()} | nil
  def delegation(repo, ticket) do
    case Enum.find(read()["delegations"], &(&1["repo"] == repo and &1["ticket"] == ticket)) do
      nil -> nil
      d -> %{epoch: d["epoch"], gateway_id: d["gateway_id"]}
    end
  end

  @spec drop_delegation(String.t(), String.t()) :: :ok | {:error, term()}
  def drop_delegation(repo, ticket),
    do: update(&%{&1 | "delegations" => Enum.reject(&1["delegations"], fn d -> d["repo"] == repo and d["ticket"] == ticket end)})

  defp peer_map(id, p) do
    at =
      case DateTime.from_iso8601(p["observed_at"] || "") do
        {:ok, dt, _} -> dt
        _ -> nil
      end

    %{gateway_id: id, label: p["label"], daemon_key: p["daemon_key"], projects: p["projects"], observed_at: at}
  end

  defp read do
    with {:ok, raw} <- File.read(path()),
         {:ok, %{} = map} <- Jason.decode(raw) do
      %{"peers" => map["peers"] || %{}, "delegations" => map["delegations"] || []}
    else
      _ -> %{"peers" => %{}, "delegations" => []}
    end
  end

  defp update(fun) do
    with :ok <- File.mkdir_p(Path.dirname(path())) do
      Aiur.Fs.atomic_write(path(), Jason.encode!(fun.(read())), mode: 0o600)
    end
  end

  defp stringify(map), do: map |> Aiur.JSONSafe.normalize() |> Map.new(fn {k, v} -> {to_string(k), v} end)
end

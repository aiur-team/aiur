defmodule Aiur.Instance.Roster do
  @moduledoc "Builds an age-aware view of instances published to the shared lease store."

  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Instance.{Identity, LeaseStore}

  @doc "Returns roster rows with observation time and explicit live/stale state."
  @spec list(keyword()) :: {:ok, map()} | {:error, term()} | :disabled
  def list(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    now_ms = DateTime.to_unix(now, :millisecond)
    retention_ms = Keyword.get(opts, :stale_retention_ms, stale_retention_ms())
    stale_after_ms = Keyword.get(opts, :stale_after_ms, 30_000)

    result =
      case Keyword.get(opts, :list_fun) do
        fun when is_function(fun, 1) -> fun.(retention_ms: retention_ms, now: now)
        _ -> LeaseStore.list_roster(retention_ms: retention_ms, now: now)
      end

    case result do
      {:ok, records} when is_list(records) ->
        case leader(opts) do
          {:error, reason} ->
            {:error, reason}

          leader ->
            rows =
              records
              |> Enum.map(&present(&1, now_ms, now, stale_after_ms, retention_ms))
              |> Enum.map(&put_leader(&1, leader))

            {:ok, %{observed_at: now, age_ms: 0, instances: Enum.reject(rows, & &1.removed?)}}
        end

      {:error, :store_not_configured} ->
        :disabled

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_roster, other}}
    end
  end

  defp leader(opts) do
    case Keyword.get(opts, :leader_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> current_repository_leader(opts)
    end
  rescue
    _ -> :unknown
  end

  defp current_repository_leader(opts) do
    repository =
      case Keyword.get(opts, :repository_fun) do
        fun when is_function(fun, 0) -> fun.()
        _ -> GitHubConfig.repo()
      end

    case repository do
      repository when is_binary(repository) and repository != "" -> LeaseStore.leader(repository)
      _ -> {:error, :repository_unavailable}
    end
  end

  defp put_leader(%{state: :stale} = row, _leader), do: Map.put(row, :leader?, false)
  defp put_leader(row, %{instance_id: id}), do: Map.put(row, :leader?, row.instance_id == id)
  defp put_leader(row, status) when status in [:unheld, :disabled], do: Map.put(row, :leader?, false)
  defp put_leader(row, _unknown), do: Map.put(row, :leader?, nil)

  defp present(record, now_ms, now, stale_after_ms, retention_ms) do
    heartbeat_ms = datetime_ms(record.heartbeat_at)
    age_ms = max(now_ms - heartbeat_ms, 0)
    metadata = metadata_data(record.metadata)
    expired? = DateTime.compare(datetime(record.expires_at), now) != :gt
    expired_age_ms = max(now_ms - datetime_ms(record.expires_at), 0)

    %{
      instance_id: record.instance_id,
      version: record.build_version,
      heartbeat_at: record.heartbeat_at,
      age_ms: age_ms,
      state: if(expired?, do: :stale, else: if(age_ms > stale_after_ms, do: :stale, else: :live)),
      removed?: expired? and expired_age_ms >= retention_ms,
      current?: record.instance_id == Identity.current(),
      host_kind: metadata["host_kind"],
      public_url: metadata["public_url"],
      leader?: metadata["leader"],
      agent_count: metadata["agent_count"],
      agent_capacity: metadata["agent_capacity"],
      held_tickets: metadata["held_tickets"],
      agents: metadata["agents"]
    }
  end

  defp datetime_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp datetime_ms(%NaiveDateTime{} = value), do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
  defp datetime(%DateTime{} = value), do: value
  defp datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp metadata_data(%{"version" => version, "data" => data}) when is_integer(version) and is_map(data), do: data
  defp metadata_data(metadata) when is_map(metadata), do: metadata

  defp stale_retention_ms do
    case Aiur.Config.settings() do
      {:ok, %{instance: %{roster_stale_retention_ms: value}}} when is_integer(value) and value >= 0 -> value
      _ -> 300_000
    end
  rescue
    _ -> 300_000
  end
end

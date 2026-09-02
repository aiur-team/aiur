defmodule Aiur.Executor.Principal do
  @moduledoc """
  Registers and renews the principal declared by an `--executor` launch.

  Recording is supervised on every run, but authority is not. This process is
  therefore started only for an Executor-owned run. It owns no wake delivery:
  `executor-wait` remains the only path that acknowledges records and advances
  the shared cursor.
  """

  use GenServer

  alias Aiur.Executor.Claims

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    claims = Keyword.get(opts, :claims, Claims)

    state = %{
      claims: claims,
      claims_opts: Keyword.take(opts, [:path, :host, :pid]),
      consumer_id: Keyword.get_lazy(opts, :consumer_id, &claims.resolve_consumer_id/0),
      renew_interval_ms: Keyword.get(opts, :renew_interval_ms, max(div(claims.lease_ttl_ms(), 3), 1_000))
    }

    case register(state) do
      {:ok, registered} -> {:ok, schedule_renewal(registered)}
      {:error, reason} -> {:stop, {:executor_principal_registration_failed, reason}}
    end
  end

  @impl true
  def handle_info(:renew, state) do
    case state.claims.renew(state.consumer_id, state.claims_opts) do
      {:ok, %{"role" => role}} when role in ["owner", "observer"] ->
        {:noreply, schedule_renewal(state)}

      {:ok, _released_or_revoked} ->
        {:noreply, state}

      {:error, :unknown_consumer} ->
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:executor_principal_renewal_failed, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = state.claims.release(state.consumer_id, state.claims_opts)
    :ok
  end

  defp register(state) do
    case state.claims.claim(state.consumer_id, state.claims_opts) do
      {:ok, _entry} -> {:ok, state}
      {:error, {:held_by, _owner}} -> observe(state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp observe(state) do
    case state.claims.observe(state.consumer_id, state.claims_opts) do
      {:ok, _entry} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_renewal(%{renew_interval_ms: interval} = state) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :renew, interval)
    state
  end
end

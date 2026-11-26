defmodule Aiur.Handoff.Protection do
  @moduledoc "Shutdown protection for runtimes committed to a durable handoff."

  alias Aiur.Project.Context

  # One entry per project (nil with no project): one project's prepare, expiry or reset
  # never touches another project's protected agents.
  defp key, do: {__MODULE__, :prepared, Context.current_id()}

  @spec prepared() :: map() | nil
  def prepared, do: :persistent_term.get(key(), nil)

  @doc "Every project's prepared entry, for machine-level callers (shutdown, guardians)."
  @spec prepared_all() :: [map()]
  def prepared_all, do: for({{__MODULE__, :prepared, _project}, value} <- :persistent_term.get(), do: value)

  @spec store(pid(), map(), MapSet.t(), [pid()], timeout()) :: :ok
  def store(owner, result, tickets, runner_pids, expires_in) do
    token = make_ref()

    prepared = %{
      owner: owner,
      result: result,
      tickets: tickets,
      runner_pids: runner_pids,
      expiry_token: token
    }

    :persistent_term.put(key(), prepared)
    Process.send_after(owner, {:handoff_expired, result.handoff_id, token}, expires_in)
    :ok
  end

  @spec take_expired(pid(), String.t(), reference()) :: {:ok, map()} | :stale
  def take_expired(owner, handoff_id, token) do
    case prepared() do
      %{owner: ^owner, result: %{handoff_id: ^handoff_id}, expiry_token: ^token} = value ->
        reset()
        {:ok, value}

      _ ->
        :stale
    end
  end

  @spec active?() :: boolean()
  def active?, do: prepared_all() != []

  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(key())
    :ok
  end

  @doc "True when any project protects the ticket; for guardians that do not know their project."
  @spec protected_anywhere?(term()) :: boolean()
  def protected_anywhere?(identifier), do: Enum.any?(prepared_all(), &MapSet.member?(&1.tickets, to_string(identifier)))

  @spec protected?(term()) :: boolean()
  def protected?(identifier) do
    case prepared() do
      %{tickets: tickets} -> MapSet.member?(tickets, to_string(identifier))
      nil -> false
    end
  end
end

defmodule Aiur.Instance.DispatchClaim do
  @moduledoc "Atomically gates workspace dispatch on the shared ticket lease."

  alias Aiur.Instance.LeaseStore

  @doc false
  @spec call(term(), (-> term()), keyword()) ::
          {:ok, :disabled | :acquired, term()} | {:error, term()}
  def call(ticket_key, dispatch_fun, opts \\ [])
      when is_function(dispatch_fun, 0) do
    claim_fun = Keyword.get(opts, :claim_fun, &LeaseStore.claim/1)

    case claim_fun.(ticket_key) do
      :disabled -> {:ok, :disabled, dispatch_fun.()}
      :acquired -> {:ok, :acquired, dispatch_fun.()}
      :held -> {:error, :shared_lease_held}
      {:error, reason} -> {:error, {:shared_lease_unavailable, reason}}
    end
  rescue
    error -> {:error, {:shared_lease_unavailable, error}}
  end
end

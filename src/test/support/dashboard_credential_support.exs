defmodule AiurWeb.DashboardCredentialSupport do
  @moduledoc false

  alias AiurWeb.Endpoint
  alias AiurWeb.FinancialDataAccess.Generation

  @endpoint_keys [:secret_key_base, :dashboard_auth_required, :dashboard_writable]
  @missing_runtime_config :__aiur_dashboard_credential_support_missing__

  def isolate(_context) do
    snapshot = snapshot()

    ExUnit.Callbacks.on_exit(fn ->
      restore_env(snapshot.username, snapshot.password)
      restore_endpoint_config(snapshot.endpoint)
      restore_runtime_config(snapshot.runtime)
      :ok = Generation.invalidate()
    end)

    # Never inherit a cached configuration generation from an earlier module.
    # Generation.current/2 rotates whenever it sees a fingerprint different
    # from the cached one, so a stale pair left behind by another writer would
    # invalidate every token this module issues (and vice versa).
    :ok = Generation.invalidate()

    :ok
  end

  defp snapshot do
    %{
      endpoint: Application.fetch_env(:aiur, Endpoint),
      password: System.get_env("AIUR_DASHBOARD_PASSWORD"),
      runtime: runtime_config(),
      username: System.get_env("AIUR_DASHBOARD_USERNAME")
    }
  end

  defp restore_env(username, password) do
    Aiur.TestSupport.restore_env("AIUR_DASHBOARD_USERNAME", username)
    Aiur.TestSupport.restore_env("AIUR_DASHBOARD_PASSWORD", password)
  end

  defp restore_endpoint_config({:ok, config}), do: put_endpoint_config(config)
  defp restore_endpoint_config(:error), do: Application.delete_env(:aiur, Endpoint)

  defp put_endpoint_config(config), do: Application.put_env(:aiur, Endpoint, config)

  defp runtime_config do
    if Process.whereis(Endpoint) do
      Map.new(@endpoint_keys, &{&1, Endpoint.config(&1, @missing_runtime_config)})
    end
  end

  defp restore_runtime_config(nil), do: :ok

  defp restore_runtime_config(config) do
    {removed, changed} = Enum.split_with(config, fn {_key, value} -> value == @missing_runtime_config end)
    put_runtime_config(changed, Enum.map(removed, &elem(&1, 0)))
  end

  defp put_runtime_config(changed, removed) do
    if Process.whereis(Endpoint) do
      # Router write gates read Phoenix's live config table while financial
      # proofs read application config, so the test boundary must align both.
      Enum.each(changed, fn {key, value} -> Phoenix.Config.put(Endpoint, key, value) end)
      Enum.each(removed, &:ets.delete(Endpoint, &1))
    end
  end
end

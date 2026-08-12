defmodule AiurWeb.DashboardCredentialSupport do
  @moduledoc false

  alias AiurWeb.Endpoint
  alias AiurWeb.FinancialDataAccess.Generation

  @endpoint_baseline [
    secret_key_base: String.duplicate("s", 64),
    dashboard_auth_required: false,
    dashboard_writable: false
  ]
  @endpoint_keys Keyword.keys(@endpoint_baseline)
  @missing_runtime_config :__aiur_dashboard_credential_support_missing__

  def isolate(_context) do
    snapshot = snapshot()

    ExUnit.Callbacks.on_exit(fn ->
      restore_env(snapshot.username, snapshot.password)
      restore_endpoint_config(snapshot.endpoint)
      restore_runtime_config(snapshot.runtime)
      :ok = Generation.invalidate()
    end)

    # Every writer starts from one coherent credential state, even when an
    # earlier test's process-local cleanup has not settled yet.
    restore_env(nil, nil)
    put_endpoint_config(endpoint_baseline(snapshot.endpoint))
    put_runtime_config(@endpoint_baseline, [])
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

  defp endpoint_baseline({:ok, config}) when is_list(config), do: Keyword.merge(config, @endpoint_baseline)
  defp endpoint_baseline(_missing), do: @endpoint_baseline

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

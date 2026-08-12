defmodule AiurWeb.DashboardCredentialSupportTest do
  use ExUnit.Case, async: false

  alias AiurWeb.Endpoint
  alias AiurWeb.FinancialDataAccess.Generation

  @endpoint_keys [:secret_key_base, :dashboard_auth_required, :dashboard_writable]
  @missing_runtime_config :__aiur_dashboard_credential_support_test_missing__

  test "resets and restores the complete credential boundary" do
    if is_nil(Process.whereis(Endpoint)), do: start_supervised!({Endpoint, []})
    original = snapshot()

    try do
      before_config =
        original.endpoint
        |> endpoint_config()
        |> Keyword.merge(
          secret_key_base: String.duplicate("b", 64),
          dashboard_auth_required: true,
          dashboard_writable: true
        )

      System.put_env("AIUR_DASHBOARD_USERNAME", "before-user")
      System.put_env("AIUR_DASHBOARD_PASSWORD", "before-password")
      Application.put_env(:aiur, Endpoint, before_config)
      put_runtime_config(before_config)
      {:ok, generation_before} = Generation.current("before")

      test_pid = self()

      isolation_pid =
        spawn_link(fn ->
          ExUnit.OnExitHandler.register(self())
          send(test_pid, {:isolated, AiurWeb.DashboardCredentialSupport.isolate(%{})})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:isolated, :ok}
      assert System.get_env("AIUR_DASHBOARD_USERNAME") == nil
      assert System.get_env("AIUR_DASHBOARD_PASSWORD") == nil
      refute Application.fetch_env!(:aiur, Endpoint)[:dashboard_auth_required]
      refute Application.fetch_env!(:aiur, Endpoint)[:dashboard_writable]
      refute Endpoint.config(:dashboard_auth_required)
      refute Endpoint.config(:dashboard_writable)
      assert {:ok, generation_after_entry} = Generation.current("before")
      refute generation_after_entry == generation_before

      System.put_env("AIUR_DASHBOARD_USERNAME", "after-user")
      System.put_env("AIUR_DASHBOARD_PASSWORD", "after-password")

      put_runtime_config(
        secret_key_base: String.duplicate("a", 64),
        dashboard_auth_required: false,
        dashboard_writable: false
      )

      assert :ok = ExUnit.OnExitHandler.run(isolation_pid, 5_000)
      send(isolation_pid, :stop)
      assert System.get_env("AIUR_DASHBOARD_USERNAME") == "before-user"
      assert System.get_env("AIUR_DASHBOARD_PASSWORD") == "before-password"
      assert Application.fetch_env!(:aiur, Endpoint) == before_config
      assert Endpoint.config(:dashboard_auth_required)
      assert Endpoint.config(:dashboard_writable)
      assert {:ok, generation_after_exit} = Generation.current("before")
      refute generation_after_exit == generation_after_entry
    after
      restore(original)
    end
  end

  defp snapshot do
    %{
      endpoint: Application.fetch_env(:aiur, Endpoint),
      password: System.get_env("AIUR_DASHBOARD_PASSWORD"),
      runtime: Map.new(@endpoint_keys, &{&1, Endpoint.config(&1, @missing_runtime_config)}),
      username: System.get_env("AIUR_DASHBOARD_USERNAME")
    }
  end

  defp endpoint_config({:ok, config}), do: config
  defp endpoint_config(:error), do: []

  defp put_runtime_config(config) do
    Enum.each(@endpoint_keys, fn key -> Phoenix.Config.put(Endpoint, key, Keyword.fetch!(config, key)) end)
  end

  defp restore(snapshot) do
    Aiur.TestSupport.restore_env("AIUR_DASHBOARD_USERNAME", snapshot.username)
    Aiur.TestSupport.restore_env("AIUR_DASHBOARD_PASSWORD", snapshot.password)

    case snapshot.endpoint do
      {:ok, config} -> Application.put_env(:aiur, Endpoint, config)
      :error -> Application.delete_env(:aiur, Endpoint)
    end

    Enum.each(snapshot.runtime, fn
      {key, @missing_runtime_config} -> :ets.delete(Endpoint, key)
      {key, value} -> Phoenix.Config.put(Endpoint, key, value)
    end)

    Generation.invalidate()
  end
end

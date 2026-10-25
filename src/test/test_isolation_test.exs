defmodule Aiur.TestSupport.IsolationTest do
  use ExUnit.Case, async: false
  require Logger

  alias Aiur.TestSupport.Isolation

  test "application environment is restored after an exception" do
    key = :isolation_restore_probe
    Application.put_env(:aiur, key, :before)
    on_exit(fn -> assert Application.get_env(:aiur, key) == :before end)

    try do
      Isolation.with_app_env!(:aiur, key, :during)
      assert Application.get_env(:aiur, key) == :during
      raise "test cleanup probe"
    rescue
      RuntimeError -> :ok
    end

    assert Application.get_env(:aiur, key) == :during
    on_exit(fn -> Application.delete_env(:aiur, key) end)
  end

  test "application environment helper rejects async use" do
    assert_raise ArgumentError, ~r/async: true/, fn ->
      Isolation.with_app_env!(:aiur, :isolation_async_probe, :value, async: true)
    end
  end

  test "owned log capture excludes an unrelated process warning" do
    owner = self()
    supervisor = Isolation.unique_name(%{module: __MODULE__, test: :owned_log}, :tasks)
    Isolation.start_owned!({Task.Supervisor, name: supervisor})

    owned =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :warn ->
            Logger.warning("owned-isolation-warning")
            send(owner, :owned_logged)
        end
      end)

    unrelated =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :warn ->
            Logger.warning("unrelated-isolation-warning")
            send(owner, :unrelated_logged)
        end
      end)

    {captured, _} =
      Isolation.capture_owned_log!([owned.pid], fn ->
        send(unrelated.pid, :warn)
        send(owned.pid, :warn)
        assert_receive :owned_logged, 1_000
        assert_receive :unrelated_logged, 1_000
        Logger.flush()
        :ok
      end)

    assert captured =~ "owned-isolation-warning"
    refute captured =~ "unrelated-isolation-warning"
    Task.shutdown(owned)
    Task.shutdown(unrelated)
  end
end

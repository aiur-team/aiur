defmodule Aiur.TestSupport.IsolationTest do
  use ExUnit.Case, async: false

  alias Aiur.TestSupport.Isolation

  test "application environment is restored after an exception" do
    key = :isolation_restore_probe
    Application.put_env(:aiur, key, :before)

    try do
      Isolation.with_app_env!(:aiur, key, :during)
      assert Application.get_env(:aiur, key) == :during
      raise "test cleanup probe"
    rescue
      RuntimeError -> :ok
    end

    assert Application.get_env(:aiur, key) == :before
    Application.delete_env(:aiur, key)
  end

  test "application environment helper rejects async use" do
    assert_raise ArgumentError, ~r/async: true/, fn ->
      Isolation.with_app_env!(:aiur, :isolation_async_probe, :value, async: true)
    end
  end

  test "owned log capture excludes an unrelated process warning" do
    owner = self()

    owned =
      spawn(fn ->
        receive do
          :warn ->
            Logger.warning("owned-isolation-warning")
            send(owner, :owned_logged)
        end
      end)

    unrelated =
      spawn(fn ->
        receive do
          :warn ->
            Logger.warning("unrelated-isolation-warning")
            send(owner, :unrelated_logged)
        end
      end)

    {captured, _} =
      Isolation.capture_owned_log!([owned], fn ->
        send(unrelated, :warn)
        send(owned, :warn)

        receive do
          :owned_logged -> :ok
        end

        receive do
          :unrelated_logged -> :ok
        end
      end)

    assert captured =~ "owned-isolation-warning"
    refute captured =~ "unrelated-isolation-warning"
    Process.exit(owned, :kill)
    Process.exit(unrelated, :kill)
  end
end

defmodule Aiur.Listener.CapabilityProviderTest do
  use ExUnit.Case, async: false

  alias Aiur.Listener.{CapabilityProvider, Scheduler}

  test "provider is registered and reads the same spec status as the scheduler in every run shape" do
    assert CapabilityProvider in Application.fetch_env!(:aiur, :capability_providers)
    assert CapabilityProvider.capability_ids() == ["listener_modes"]

    expected =
      case Scheduler.spec_status() do
        :ok -> %{state: :available, version: 1}
        {:error, :not_installed} -> %{state: :unavailable, reason: :not_installed}
        {:error, :spec_invalid} -> %{state: :unavailable, reason: :spec_invalid}
      end

    for shape <- [%{}, %{http_listener: false}, %{http_listener: true, dashboard_pages: false}] do
      assert CapabilityProvider.capabilities(%{run_shape: shape, settings: :unavailable}) == %{"listener_modes" => expected}
    end
  end

  test "spec absent reports unavailable/not_installed" do
    assert entry(fn -> {:error, :not_installed} end) == %{"listener_modes" => %{state: :unavailable, reason: :not_installed}}
  end

  test "checksum failure reports unavailable/spec_invalid" do
    assert entry(fn -> {:error, :spec_invalid} end) == %{"listener_modes" => %{state: :unavailable, reason: :spec_invalid}}
  end

  test "spec ok reports available with the selected spec major" do
    assert entry(fn -> :ok end) == %{"listener_modes" => %{state: :available, version: 1}}
  end

  test "raising, exiting, throwing and unexpected spec status report unknown/unknown" do
    for fun <- [fn -> raise "spec failed" end, fn -> exit(:unavailable) end, fn -> throw(:unavailable) end, fn -> :unexpected end] do
      assert entry(fun) == %{"listener_modes" => %{state: :unknown, reason: :unknown}}
    end
  end

  defp entry(fun), do: CapabilityProvider.capabilities(%{}, spec_status_fun: fun)
end

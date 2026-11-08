defmodule Aiur.ProviderMeterProjectionSharedTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderMeterProjection

  test "a blocked shared database refresh does not block local provider reads" do
    parent = self()

    projection =
      start_supervised!(
        {ProviderMeterProjection,
         [
           name: nil,
           subscribe?: false,
           shared_refresh_interval_ms: 60_000,
           shared_refresh_fun: fn ->
             send(parent, {:shared_read_started, self()})
             receive do: (:release -> %{})
           end
         ]}
      )

    send(projection, :refresh_shared_observations)
    assert_receive {:shared_read_started, fetcher}, 1_000

    read = Task.async(fn -> ProviderMeterProjection.provider_view(projection, :codex) end)
    assert {:ok, %{state: :unknown}} = Task.yield(read, 1_000)

    send(fetcher, :release)
  end
end

defmodule Aiur.Listener.DeliveryTargetTest do
  use ExUnit.Case, async: false

  alias Aiur.Listener

  defmodule SnapshotTarget do
    @behaviour Aiur.Listener.DeliveryTarget
    @impl true
    def enqueue(_target, _text, _opts), do: {:error, :unsupported}
    @impl true
    def get_mode(_target), do: {:error, :unsupported}
    @impl true
    def set_mode(_target, _mode, _opts), do: {:error, :unsupported}
    @impl true
    def read_snapshot(id, timeout) do
      send(self(), {:snapshot_read, id, timeout})
      {:ok, nil}
    end
  end

  test "receipt uses the registered delivery target and forwards the read timeout" do
    original = Application.fetch_env!(:aiur, :listener_delivery_target)
    Application.put_env(:aiur, :listener_delivery_target, SnapshotTarget)
    on_exit(fn -> Application.put_env(:aiur, :listener_delivery_target, original) end)

    assert {:ok, %{receipt: :unknown, queue_status: :unknown, listener_mode: nil}} = Listener.receipt(73, 42)
    assert_received {:snapshot_read, 73, 42}
  end
end

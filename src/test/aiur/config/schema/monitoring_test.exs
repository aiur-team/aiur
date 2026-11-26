defmodule Aiur.Config.Schema.MonitoringTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.Monitoring

  describe "changeset/2" do
    test "accepts valid attributes" do
      changeset = Monitoring.changeset(%Monitoring{}, %{"daemon_heartbeat_stale_ms" => 7_200_000})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :daemon_heartbeat_stale_ms) == 7_200_000
    end

    test "accepts empty attributes and uses defaults" do
      changeset = Monitoring.changeset(%Monitoring{}, %{})
      assert changeset.valid?
      # Default is applied by the schema
      assert Ecto.Changeset.apply_changes(changeset).daemon_heartbeat_stale_ms == 3_600_000
    end

    test "rejects zero value" do
      changeset = Monitoring.changeset(%Monitoring{}, %{"daemon_heartbeat_stale_ms" => 0})
      refute changeset.valid?
      assert changeset.errors[:daemon_heartbeat_stale_ms]
    end

    test "rejects negative values" do
      changeset = Monitoring.changeset(%Monitoring{}, %{"daemon_heartbeat_stale_ms" => -1})
      refute changeset.valid?
      assert changeset.errors[:daemon_heartbeat_stale_ms]
    end

    test "accepts positive values" do
      changeset = Monitoring.changeset(%Monitoring{}, %{"daemon_heartbeat_stale_ms" => 1})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :daemon_heartbeat_stale_ms) == 1
    end
  end
end

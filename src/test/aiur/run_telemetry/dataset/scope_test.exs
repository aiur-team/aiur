defmodule Aiur.RunTelemetry.Dataset.ScopeTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Dataset

  @fixtures Path.expand("../../../fixtures/run_telemetry", __DIR__)

  describe "filter/2" do
    test "boot_ids/1 lists every session in the stream, oldest first" do
      {:ok, dataset} = Dataset.build(@fixtures)

      assert Dataset.boot_ids(dataset) == ["boot-a", "boot-b"]
    end

    test "scoping to one session keeps only that boot's records" do
      {:ok, dataset} = Dataset.build(@fixtures)

      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      assert scoped.records |> Enum.map(& &1.boot_id) |> Enum.uniq() == ["boot-b"]
      assert Enum.map(scoped.restarts, & &1.boot_id) == ["boot-b"]
    end

    test "an actor with no samples in the session is dropped rather than kept empty" do
      {:ok, dataset} = Dataset.build(@fixtures)

      assert Map.has_key?(dataset.actors, "_operator")

      # The operator only sampled during boot-a; a zero-sample shell would render
      # as a real actor burning nothing.
      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      refute Map.has_key?(scoped.actors, "_operator")
      assert Map.has_key?(scoped.actors, "_daemon")
    end

    test "per-actor statistics are recomputed from the surviving samples" do
      {:ok, dataset} = Dataset.build(@fixtures)
      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      full = get_in(dataset.actors, ["_daemon", :profile, "cpu_percent", :count])
      session = get_in(scoped.actors, ["_daemon", :profile, "cpu_percent", :count])

      assert session < full
      assert session == length(scoped.actors["_daemon"].samples)
    end

    test "a ticket whose lifecycle predates the session drops out of the scope" do
      {:ok, dataset} = Dataset.build(@fixtures)

      assert Map.has_key?(dataset.tickets, "931")

      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      refute Map.has_key?(scoped.tickets, "931")
      assert Map.has_key?(scoped.tickets, "930")
    end

    test "surviving lifecycle intervals are re-paired within the session" do
      {:ok, dataset} = Dataset.build(@fixtures)
      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      phases = scoped.tickets["930"].intervals |> Enum.map(& &1.phase) |> Enum.uniq() |> Enum.sort()

      assert "build_test" in phases
      assert Enum.all?(scoped.tickets["930"].events, &(&1.boot_id == "boot-b"))
    end

    test "scoping to a ticket set keeps the shared baseline actors" do
      {:ok, dataset} = Dataset.build(@fixtures)

      scoped = Dataset.filter(dataset, tickets: MapSet.new(["930"]))

      assert Map.keys(scoped.tickets) == ["930"]
      # Daemon and executor cost is orchestration overhead, not per-ticket cost,
      # so it is never filtered away with the tickets.
      assert Map.has_key?(scoped.actors, "_daemon")
      assert Map.has_key?(scoped.actors, "_operator")
    end

    test "scoping to an empty ticket set yields no tickets rather than every ticket" do
      {:ok, dataset} = Dataset.build(@fixtures)

      scoped = Dataset.filter(dataset, tickets: MapSet.new())

      assert scoped.tickets == %{}
    end

    test "provenance is rescoped so the window reflects the filtered records" do
      {:ok, dataset} = Dataset.build(@fixtures)
      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      assert scoped.provenance.record_count == length(scoped.records)
      assert scoped.provenance.time_range.start >= dataset.provenance.time_range.start
    end

    test "no options is a no-op" do
      {:ok, dataset} = Dataset.build(@fixtures)

      assert Dataset.filter(dataset, []) == dataset
    end
  end
end

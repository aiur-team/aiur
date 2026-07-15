defmodule Aiur.CurrentRunMembership.CheckpointTest do
  use ExUnit.Case, async: true

  alias Aiur.CurrentRunMembership.{Event, Event.Codec, Projection}
  alias Aiur.CurrentRunMembership.Store.{Checkpoint, FileOps}
  alias Aiur.TrackerIdentity

  @run_id "checkpoint-codec-test"
  @observed_at ~U[2026-07-14 12:00:00Z]

  test "rejects a checksummed checkpoint member with content-bearing keys" do
    {:ok, event} = Event.new(@run_id, identity(), :queued, @observed_at)
    {:accepted, projection} = Projection.apply(Projection.new(@run_id), event)
    record = Checkpoint.record(projection)
    [member] = record["members"]
    members = [Map.put(member, "title", "must not persist")]
    record = record |> Map.put("members", members) |> Map.put("checksum", checksum(record, members))

    assert {:error, :invalid_checkpoint} = Checkpoint.from_record(record, @run_id)
  end

  test "refuses an oversized checkpoint before it can replace replayable recovery data" do
    oversized = %{"members" => [String.duplicate("x", Codec.max_checkpoint_bytes())]}
    path = Path.join(System.tmp_dir!(), "aiur-oversized-checkpoint-#{System.unique_integer([:positive])}")

    assert {:error, :record_too_large} = Codec.validate_checkpoint_record_size(oversized)
    assert {:error, :record_too_large} = FileOps.write_checkpoint(path, oversized)
    refute File.exists?(path)
  end

  defp checksum(record, members) do
    {record["version"], record["run_id"], record["generation"], members}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp identity do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I-checkpoint",
      identifier: "42",
      reason: nil
    }
  end
end

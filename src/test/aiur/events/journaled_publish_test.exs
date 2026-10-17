defmodule Aiur.Events.JournaledPublishTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.JournaledPublish

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-journaled-publish")
    {:ok, dir: dir, journal: Path.join(dir, "events.jsonl")}
  end

  test "appends the normalized record before fan-out", %{dir: dir, journal: journal} do
    :ok = Exchange.subscribe("executor.test.ordered")
    parent = self()

    task =
      Task.async(fn ->
        :ok = Exchange.subscribe("executor.test.ordered")
        send(parent, :subscribed)

        receive do
          {:event, %{id: id}} -> File.read!(journal) =~ ~s("id":#{id})
        after
          1_000 -> :timeout
        end
      end)

    assert_receive :subscribed, 500
    assert {:ok, _id, _count} = JournaledPublish.publish("executor.test.ordered", %{n: 1}, journal: journal, journal_dir: dir)
    assert Task.await(task) == true
  end

  test "a failed append publishes nothing", %{dir: dir} do
    File.mkdir_p!(dir)
    not_a_dir = Path.join(dir, "file")
    File.write!(not_a_dir, "x")
    :ok = Exchange.subscribe("executor.test.failed")

    assert {:error, _} =
             JournaledPublish.publish("executor.test.failed", %{n: 1}, journal: Path.join(not_a_dir, "j.jsonl"), journal_dir: not_a_dir)

    refute_receive {:event, _}, 100
  end

  test "journal line carries the string source and the normalized payload", %{dir: dir, journal: journal} do
    :ok = Exchange.subscribe("executor.test.normalized")
    payload = %{at: ~U[2026-10-06 12:00:00Z], kind: :x, pair: {1, :a}}

    assert {:ok, id, _} = JournaledPublish.publish("executor.test.normalized", payload, journal: journal, journal_dir: dir, source: :executor_cli)

    line = File.read!(journal)
    assert line =~ ~s("at":"2026-10-06T12:00:00Z")
    assert line =~ ~s("kind":"x")
    assert line =~ ~s("pair":[1,"a"])
    assert line =~ ~s("source":"executor_cli")
    assert_receive {:event, %{id: ^id, kind: :x}}, 500
  end
end

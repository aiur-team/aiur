defmodule Aiur.Events.Export.ReaderTest do
  use ExUnit.Case, async: false
  alias Aiur.Events.{Envelope, Export}

  test "500 matching records page across segments while ignoring other topics" do
    root = Path.join(System.tmp_dir!(), "export-reader-#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:aiur, :runtime_state_dir)
    previous_status = :persistent_term.get({Export, :status}, nil)
    Application.put_env(:aiur, :runtime_state_dir, root)

    on_exit(fn ->
      Application.put_env(:aiur, :runtime_state_dir, previous_root)
      if previous_status, do: :persistent_term.put({Export, :status}, previous_status), else: :persistent_term.erase({Export, :status})
      Aiur.TestCleanup.rm_rf!(root)
    end)

    dir = Path.join(root, "events/export")
    File.mkdir_p!(dir)

    records =
      for seq <- 1..1200 do
        topic = if rem(seq, 2) == 0, do: "ticket.42.pr.merged", else: "ticket.43.pr.merged"
        {:ok, envelope} = Envelope.to_external(%{id: seq, topic: topic}, instance: "test/instance")
        Map.merge(envelope, %{"type" => "event", "seq" => seq})
      end

    for {chunk, first} <- [{Enum.take(records, 700), 1}, {Enum.drop(records, 700), 701}] do
      File.write!(Path.join(dir, "seg.#{first}.ndjson"), Enum.map_join(chunk, "", &(Jason.encode!(&1) <> "\n")))
    end

    # Reader projection fixture: production status publication is exercised in ExporterTest.
    :persistent_term.put({Export, :status}, %{state: :available, reason: nil, instance: "test/instance", epoch: "fixture", oldest_seq: 1, head_seq: 1200})
    assert {:ok, %{records: first, head_seq: 1200}} = Export.read(0, 500, ["ticket.42.#"])
    assert Enum.map(first, & &1["seq"]) == Enum.to_list(2..1000//2)
    assert {:ok, %{records: second}} = Export.read(1000, 500, ["ticket.42.#"], epoch: "fixture")
    assert Enum.map(second, & &1["seq"]) == Enum.to_list(1002..1200//2)
    File.rm!(Path.join(dir, "seg.701.ndjson"))
    assert Export.read(1000, 500, ["ticket.42.#"]) == {:error, :events_unavailable}
  end
end

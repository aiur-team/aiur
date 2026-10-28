defmodule Aiur.Conversation.SubjectIndexTest do
  use ExUnit.Case, async: true

  alias Aiur.Conversation.{Ref, SubjectIndex}
  alias Aiur.TestCleanup
  alias Aiur.TrackerIdentity
  import ExUnit.CaptureLog

  setup do
    root = Path.join(System.tmp_dir!(), "subject-index-#{System.unique_integer([:positive])}")
    {:ok, pid} = SubjectIndex.start_link(root_fun: fn -> {:ok, root} end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      TestCleanup.rm_rf!(root)
    end)

    %{root: root, server: pid}
  end

  test "skips a corrupt subject and keeps resolving healthy records", context do
    identity = identity()
    {:ok, ref} = Ref.worker(identity)
    id = Ref.conversation_id(ref)
    good = Path.join(context.root, id)
    bad = Path.join(context.root, "conv_bad")
    File.mkdir_p!(good)
    File.mkdir_p!(bad)
    File.write!(Path.join(bad, "subject.json"), "{")

    File.write!(
      Path.join(good, "subject.json"),
      Jason.encode!(%{
        "v" => 1,
        "conversation_id" => id,
        "kind" => "worker",
        "owner" => identity.owner,
        "repository" => identity.repository,
        "provider_id" => identity.provider_id
      })
    )

    log = capture_log(fn -> assert {:ok, ^id} = SubjectIndex.lookup(identity, server: context.server) end)
    assert log =~ "skipped 1 unreadable subject.json file(s)"
    assert {:ok, index} = SubjectIndex.index(server: context.server)
    assert Enum.count(index) == 1
  end

  test "repeated lookups reuse the scan until invalidated", context do
    parent = self()
    counter = :atomics.new(1, [])

    {:ok, pid} =
      SubjectIndex.start_link(
        root_fun: fn -> {:ok, context.root} end,
        scan_fun: fn _root ->
          :atomics.add_get(counter, 1, 1)
          send(parent, :scanned)
          {:ok, %{}, 0}
        end
      )

    identity = identity()
    assert {:error, :not_found} = SubjectIndex.lookup(identity, server: pid)
    assert {:error, :not_found} = SubjectIndex.lookup(identity, server: pid)
    assert_receive :scanned, 1000
    refute_receive :scanned, 50
    assert :atomics.get(counter, 1) == 1
    SubjectIndex.invalidate(server: pid)
    assert {:error, :not_found} = SubjectIndex.lookup(identity, server: pid)
    assert_receive :scanned, 1000
    assert :atomics.get(counter, 1) == 2
    GenServer.stop(pid)
  end

  test "a live identity resolves without consulting a failing disk scan", context do
    identity = identity()
    {:ok, ref} = Ref.worker(identity)
    id = Ref.conversation_id(ref)
    snapshot_fun = fn -> {:ok, [%{tracker_identity: identity}]} end
    scan_fun = fn _root -> raise "disk scan should not run" end
    {:ok, pid} = SubjectIndex.start_link(root_fun: fn -> {:ok, context.root} end, scan_fun: scan_fun)

    assert {:ok, ^id} = SubjectIndex.lookup_or_live(identity, server: pid, snapshot_fun: snapshot_fun)
    GenServer.stop(pid)
  end

  defp identity do
    %TrackerIdentity{status: :joinable, kind: :github, owner: "acme", repository: "app", provider_id: "I_issue", identifier: "1", reason: nil}
  end
end

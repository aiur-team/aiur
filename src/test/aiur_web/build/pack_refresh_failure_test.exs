defmodule AiurWeb.Build.PackRefreshFailureTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.{Index, IndexReader}

  test "timed out pack refresh invalidates cached manifest counts as well as planned rows" do
    parent = self()
    feature = %{slug: "bo-99", label: "Program", hue: 40, epics: [%{key: "f-bo-99-core", label: "Core"}], from: now(), to: :none, baseline: :none}
    registry = %{features: %{"bo-99" => feature}, owners: %{}, also: %{}, health: health()}
    input = Map.put(parts(), :features, {:ok, registry})
    manifest = %{root_number: 99, metadata: %{}, tickets: [%{id: "A", lane: "core", number: nil}]}
    initial = IndexReader.read(MapSet.new([:packs]), input, pack_loader: fn -> [manifest] end, packs_opts: [loader: fn -> %{configured: 0, packs: [], failed: []} end], clock: &now/0)

    reader = fn _dirty, previous, _opts ->
      if map_size(previous) == 0 do
        initial
      else
        Aiur.BuildOrder.Index.safe_read(:packs, fn ->
          send(parent, {:pack_read_started, self()})

          receive do
            :release -> previous
          end
        end)
      end
    end

    server =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: reader,
         clock: &now/0,
         timer: fn _, _, _ -> make_ref() end,
         daemon_timer: fn _, _, _ -> make_ref() end,
         daemon_read: fn _ -> %{state: "unknown", heartbeat_at: nil, observed_at: now()} end,
         broadcast: fn change -> send(parent, {:index_changed, change}) end}
      )

    assert {:ok, before} = Index.window(server, "Etc/UTC")
    assert before.feature_progress.features["f-bo-99-core"].unpublished == 1
    send(server, {:build_order_pack_status_changed, %{}})
    send(server, :flush)
    assert_receive {:pack_read_started, _worker}, 1000
    send(server, {:read_timeout, :sys.get_state(server).task.ref})
    assert_receive {:index_changed, %{set: %{sources: %{packs: %{state: "unavailable"}}}}}, 1000
    assert {:ok, after_timeout} = Index.window(server, "Etc/UTC")
    progress = after_timeout.feature_progress
    assert progress.features["f-bo-99-core"].unpublished == nil
    assert progress.features["f-bo-99-core"].total == nil
    assert progress.features["f-bo-99-core"].reason =~ "planned count unavailable"
    assert :sys.get_state(server).parts.feature_packs == {:error, :read_failed}
  end
end

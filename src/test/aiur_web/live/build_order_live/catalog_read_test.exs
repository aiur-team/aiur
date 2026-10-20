defmodule AiurWeb.BuildOrderLive.CatalogReadTest do
  # #4873: every catalog read runs off the LiveView process, is bounded, can be
  # restarted from Refresh catalog, and reports a failure age that stops counting.
  use AiurWeb.BuildOrderLiveCase

  # A catalog read that reports its task and holds until the test answers it.
  defp held_catalog do
    test = self()

    fn ->
      send(test, {:catalog_reading, self()})

      receive do
        {:release_catalog, catalog} -> catalog
        # Only a throw gets past `safe_source_call` to the task's `{:exit, _}`.
        :crash_catalog -> throw(:catalog_crashed)
      end
    end
  end

  defp assert_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  defp catalog_reads(source), do: Enum.count(FakeDataSource.calls(source), &(&1 == {:catalog, []}))

  defp ready_catalog, do: catalog_snapshot([root(identity(42, "NODE-42"), "Recovered root")], 1, :healthy)

  defp use_display_clock do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    clock = start_supervised!({Agent, fn -> observed_at end})
    Application.put_env(:aiur, :build_order_display_clock, fn -> Agent.get(clock, & &1) end)
    clock
  end

  defp advance(view, clock, seconds) do
    Agent.update(clock, &DateTime.add(&1, seconds, :second))
    send(view.pid, :build_order_ui_tick)
    render(view)
  end

  test "live-state events and resets read the catalog without blocking the page", %{source: source} do
    assert {:ok, view, _html} = live_settled("/build-orders")
    reads = catalog_reads(source)
    :ok = FakeDataSource.put_catalog(source, held_catalog())

    send(view.pid, {:current_run_membership_changed, %{}})
    assert render(view) =~ "build-orders-refresh-catalog"
    assert_receive {:catalog_reading, task}, 1_000

    # A second event and a reset while the read is held queue one rerun rather
    # than stacking reads on the stuck one.
    send(view.pid, {:build_order_pack_status_changed, :healthy})
    send(view.pid, {:graph_projection_reset, 2})
    assert render(view) =~ ~s(data-build-order-catalog-state="loading")
    assert catalog_reads(source) == reads + 1

    send(task, {:release_catalog, ready_catalog()})
    assert_receive {:catalog_reading, rerun}, 1_000
    assert rerun != task
    send(rerun, {:release_catalog, put_in(ready_catalog().authority_epoch, 2)})
    assert settle(view) =~ "Recovered root"
    assert catalog_reads(source) == reads + 2
  end

  test "a read past its timeout becomes the named failure" do
    test = self()
    previous = Application.get_env(:aiur, :build_order_catalog_timeout_scheduler)

    Application.put_env(:aiur, :build_order_catalog_timeout_scheduler, fn pid, ref, timeout ->
      send(test, {:catalog_timeout_scheduled, pid, ref, timeout})
      Process.send_after(pid, {:build_order_catalog_timeout, ref}, timeout)
    end)

    on_exit(fn -> restore_application_env(:build_order_catalog_timeout_scheduler, previous) end)
    install_source(catalog: held_catalog())

    assert {:ok, view, _html} = live(build_conn(), "/build-orders")
    assert_receive {:catalog_reading, task}, 1_000
    assert_receive {:catalog_timeout_scheduled, pid, ref, 30_000}, 1_000
    assert pid == view.pid

    send(view.pid, {:build_order_catalog_timeout, ref})
    html = render(view)

    assert html =~ ~s(data-build-order-catalog-state="read_failed")
    assert html =~ "Build Order catalog read failed"
    assert_down(task)
  end

  @tag :capture_log
  test "a crashed read is named as failed and its age stops counting" do
    clock = use_display_clock()
    install_source(catalog: held_catalog())

    assert {:ok, view, _html} = live(build_conn(), "/build-orders")
    assert_receive {:catalog_reading, task}, 1_000
    advance(view, clock, 3)
    send(task, :crash_catalog)
    assert_down(task)
    html = render(view)

    assert html =~ ~s(data-build-order-catalog-state="read_failed")
    assert html =~ "returned no Build Order list after 3 seconds"

    html = advance(view, clock, 10)
    assert html =~ "returned no Build Order list after 3 seconds"
  end

  test "Refresh catalog restarts a stuck read" do
    source = install_source(catalog: held_catalog())

    assert {:ok, view, _html} = live(build_conn(), "/build-orders")
    assert_receive {:catalog_reading, stuck}, 1_000

    :ok = FakeDataSource.put_catalog(source, ready_catalog())
    view |> element("#build-orders-refresh-catalog") |> render_click()
    html = settle(view)

    assert html =~ ~s(data-build-order-catalog-state="ready")
    assert html =~ "Recovered root"
    assert_down(stuck)
  end
end

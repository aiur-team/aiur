defmodule Aiur.EpicCLIConfirmTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Aiur.BuildOrder.EpicOverrides, as: Store
  alias Aiur.EpicCLI

  setup do
    dir = Aiur.TestSupport.tmp_root!("epic-cli-confirm")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    settings = fn -> {:ok, %{build_order: %{general_epics: [%{key: "infra", label: "Infra"}, %{key: "design", label: "Design"}]}}} end
    start_supervised!({Store, name: name, repository: "acme/app", state_dir: dir, settings_fun: settings})
    opts = [server: name, error_fun: fn _ -> :ok end]
    assert {:ok, _} = Store.set("infra", [12], %{actor: "agent:2790", source: "backfill-agent"}, opts)
    assert {:ok, _} = Store.set("infra", [13], %{actor: "cli:tester", source: "cli:tester"}, opts)
    %{opts: opts}
  end

  test "unconfirmed listing filters rows and counts only selected guesses", c do
    text = run(c.opts ++ [action: :show, unconfirmed: true], 0)
    assert text =~ "#12  infra"
    assert text =~ "backfill-agent  unconfirmed"
    refute text =~ "#13"
    assert String.ends_with?(text, "1 unconfirmed\n")
    json = run(c.opts ++ [action: :show, unconfirmed: true, json: true], 0) |> Jason.decode!()
    assert json["unconfirmed_count"] == 1
    assert [%{"number" => 12, "confirmed" => false}] = json["overrides"]
    assert run(c.opts ++ [action: :show, ids: [13], unconfirmed: true], 0) == "0 unconfirmed\n"
  end

  test "confirm JSON carries accepted epic and atomic previous provenance", c do
    opts = c.opts ++ [action: :confirm, ids: [12, 13], who: "kevin", json: true]
    json = run(opts, 0) |> Jason.decode!()
    assert json["command"] == "epic confirm"
    assert [%{"number" => 12, "status" => "confirmed", "epic" => "infra", "previous" => %{"source" => "backfill-agent"}}, %{"status" => "unchanged"}] = json["results"]
    assert run(Keyword.delete(opts, :json), 0) =~ "unchanged (already confirmed)"
  end

  test "refusal JSON lists every invalid id and leaves accepted rows untouched", c do
    Store.set("design", [16], %{actor: "agent:2790", source: "backfill-agent"}, c.opts)
    json = run(c.opts ++ [action: :confirm, ids: [12, 15, 16], expect_epic: "infra", who: "kevin", json: true], 1) |> Jason.decode!()
    assert json["ok"] == false
    assert json["refused"] == [%{"number" => 15, "reason" => "no_override"}, %{"number" => 16, "reason" => "epic_changed", "current" => "design"}]
    assert {:ok, %{12 => %{confirmed: false}}, _} = Store.get_many([12], c.opts)
  end

  @tag :future_regression
  test "future regression guard: unavailable listing gives an error without a count", c do
    stop_supervised!(Store)
    opts = Keyword.put(c.opts, :error_fun, &IO.puts/1) ++ [action: :show, unconfirmed: true]
    text = run(opts, 1)
    assert text =~ "epic overrides unavailable"
    refute text =~ ~r/^\d+ unconfirmed$/m
    json = run(c.opts ++ [action: :show, unconfirmed: true, json: true], 1) |> Jason.decode!()
    assert json["ok"] == false
    assert json["health"]["failure"] == "epic_overrides_not_running"
    refute Map.has_key?(json, "unconfirmed_count")
  end

  defp run(opts, code), do: capture_io(fn -> assert EpicCLI.run(opts) == code end)
end

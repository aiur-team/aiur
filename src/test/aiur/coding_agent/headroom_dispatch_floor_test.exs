defmodule Aiur.CodingAgent.HeadroomDispatchFloorTest do
  @moduledoc """
  The remaining-usage floor (#7504) under `account_selection: headroom`.

  Split from `Aiur.CodingAgent.HeadroomDispatchTest` so each file stays small;
  the helpers below mirror that module's fixtures.
  """

  use Aiur.TestSupport

  alias Aiur.Accounts.UsageReadings
  alias Aiur.CodingAgent
  alias Aiur.Issue

  @now ~U[2026-10-10 06:00:00Z]
  @future "2999-01-01T00:00:00Z"

  # Codex: 6% left on its weekly window, read from the usage ledger — just above
  # the default 5% usage floor, so headroom scoring still selects it.
  @ledger %{"backends" => %{"codex" => %{"observed_at" => "2026-10-10T05:59:30Z", "weekly" => %{"used" => 94, "limit" => 100, "reset_at" => @future}}}}

  # Claude/default 100% left, Claude/everdred 64% left.
  @healthy %{"default" => {0, 0}, "everdred" => {36, 10}}

  defp meters(by_account) do
    fn
      "claude", names ->
        for name <- names, Map.has_key?(by_account, name), into: %{} do
          {seven_day, five_hour} = Map.fetch!(by_account, name)

          {name,
           %{
             reading: %{windows: [%{window: "seven_day", used_percent: seven_day}, %{window: "five_hour", used_percent: five_hour}]},
             observed_at: @now,
             freshness: :fresh
           }}
        end

      _harness, _names ->
        %{}
    end
  end

  defp opts(overrides) do
    ledger_path = Path.join(Aiur.TestSupport.tmp_root!("headroom-floor-ledger"), "model-usage.json")
    File.mkdir_p!(Path.dirname(ledger_path))
    File.write!(ledger_path, Jason.encode!(%{"backends" => %{}}))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(Path.dirname(ledger_path)) end)

    Keyword.merge(
      [
        account_selection: "headroom",
        routing_candidates: %{3 => ["claude:sonnet", "codex:gpt-5.5:high"]},
        priority_backends: ["claude", "codex"],
        backends: ["claude", "codex"],
        configured_backends: ["claude", "codex"],
        accounts: %{"claude" => ["default", "everdred"]},
        account_list_fun: fn
          "claude" -> [%{name: "default"}, %{name: "everdred"}]
          _harness -> []
        end,
        account_capability_fun: fn
          "claude" -> {:ok, %{supported: true, multi: :available}}
          _harness -> {:error, :unsupported_account_backend}
        end,
        usage_snapshot: meters(@healthy),
        state: @ledger,
        path: ledger_path,
        probe_fun: fn _backend, _options -> :ok end,
        avoid_peak_pricing: false,
        now: @now
      ],
      overrides
    )
  end

  defp ticket(labels \\ ["complexity:3"]), do: %Issue{id: "id-1", identifier: "T-1", labels: labels}

  defp select(issue, overrides), do: CodingAgent.select_for_dispatch(issue, opts(overrides))

  # The default floor (5) from config, with codex loosened to 2 so the
  # per-backend override is visible in the same run.
  defp floor_fun do
    fn
      "codex" -> 2
      _backend -> 5
    end
  end

  defp floored_opts(overrides) do
    Keyword.merge([usage_floor_percent_fun: floor_fun()], overrides)
  end

  # Claude/default has 4% left, Claude/everdred 3%: both accounts are at the
  # floor, so the whole route is skipped.
  defp both_claude_accounts_floored, do: meters(%{"default" => {96, 0}, "everdred" => {97, 0}})

  setup do
    UsageReadings.reset()
    on_exit(&UsageReadings.reset/0)
    :ok
  end

  describe "issue #7504 usage floor" do
    test "a backend at the floor is skipped and the next allowed route takes the dispatch" do
      assert {:ok, %Issue{selected_backend: "codex"} = issue} =
               select(ticket(), floored_opts(usage_snapshot: both_claude_accounts_floored()))

      # The dispatch record keeps the skipped route and names the window that
      # held it, so the operator can see why an enabled login was passed over.
      assert [%{name: "claude/default", status: :held, held: held_line}, %{name: "claude/everdred", status: :held}] =
               Enum.filter(issue.dispatch_selection.candidates, &(&1.status == :held))

      assert held_line =~ "4% left ≤ 5% floor"
      assert issue.dispatch_selection.summary =~ "held claude/default"
    end

    test "an account just above the floor is still used" do
      assert {:ok, %Issue{selected_backend: "claude", selected_account: "everdred"} = issue} =
               select(ticket(), floored_opts(usage_snapshot: meters(%{"default" => {94, 0}, "everdred" => {90, 0}})))

      refute Enum.any?(issue.dispatch_selection.candidates, &(&1.status == :held))
      assert issue.dispatch_selection.summary =~ "claude/everdred=10%"
      assert issue.dispatch_selection.summary =~ "claude/default=6%"
    end

    test "a floored weekly window skips the account while the 5-hour window is fine" do
      # default: weekly 4% left, 5-hour untouched -> skipped.
      # everdred: healthy -> the route survives and takes the dispatch.
      assert {:ok, %Issue{selected_backend: "claude", selected_account: "everdred"} = issue} =
               select(ticket(), floored_opts(usage_snapshot: meters(%{"default" => {96, 10}, "everdred" => {36, 10}})))

      assert [%{name: "claude/default", status: :held, binding_window: "seven_day"}] =
               Enum.filter(issue.dispatch_selection.candidates, &(&1.status == :held))

      refute Enum.any?(issue.dispatch_selection.candidates, &(&1.name == "claude/everdred" and &1.status == :held))
    end

    test "the per-backend floor override keeps a route the global floor would hold" do
      # Codex has 4% left: held under the global floor of 5, allowed under its
      # own override of 2. Claude is floored either way.
      snapshot = meters(%{"default" => {96, 0}, "everdred" => {97, 0}})
      ledger = put_in(@ledger, ["backends", "codex", "weekly", "used"], 96)

      assert {:ok, %Issue{selected_backend: "codex"}} =
               select(ticket(), floored_opts(usage_snapshot: snapshot, state: ledger))

      assert {:all_limited, _routes} =
               select(ticket(), usage_floor_percent_fun: fn _backend -> 5 end, usage_snapshot: snapshot, state: ledger)
    end

    test "an unknown reading is never floored" do
      # Codex has no ledger entry: its reading is unknown, so the floor leaves it
      # alone and headroom still explores it.
      assert {:ok, %Issue{selected_backend: "codex"} = issue} =
               select(ticket(), floored_opts(usage_snapshot: both_claude_accounts_floored(), state: %{"backends" => %{}}))

      assert issue.dispatch_selection.summary =~ "codex=unknown"
    end

    test "a route comes back on its own when its window resets" do
      {:ok, first} = select(ticket(), floored_opts(usage_snapshot: both_claude_accounts_floored()))
      assert first.selected_backend == "codex"

      # No config edit: the next dispatch reads the fresh meters and uses Claude.
      assert {:ok, %Issue{selected_backend: "claude", selected_account: "default"}} =
               select(first, floored_opts(usage_snapshot: meters(%{"default" => {0, 0}, "everdred" => {20, 0}})))
    end

    test "with every route floored the claim is held, not failed" do
      floored_ledger = %{"backends" => %{"codex" => %{"observed_at" => "2026-10-10T05:59:30Z", "weekly" => %{"used" => 98, "limit" => 100, "reset_at" => @future}}}}

      assert {:all_limited, routes} =
               select(ticket(), floored_opts(usage_snapshot: both_claude_accounts_floored(), state: floored_ledger))

      assert Enum.sort(routes) == ["claude:sonnet", "codex:gpt-5.5:high"]
    end
  end
end

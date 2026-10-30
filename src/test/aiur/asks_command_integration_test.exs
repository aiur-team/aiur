Code.require_file("../support/decision_store_case.ex", __DIR__)

defmodule Aiur.AsksCommandIntegrationTest do
  use Aiur.DecisionStoreCase, async: false
  import ExUnit.CaptureIO

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end})
    %{store: store}
  end

  test "unavailable Command store fails without writing a legacy ask", %{dir: dir} do
    previous = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, Path.join(dir, "legacy"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :repo_base_root, previous), else: Application.delete_env(:aiur, :repo_base_root)
    end)

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          Aiur.AsksCLI.rpc(["ask", "Approve release?"], "caller", decision_store: :absent_ask_store)
        end)
      end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: command request cannot create Command"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
    assert {:ok, []} = Aiur.Asks.all("owner/no-fallback")
  end

  test "RPC entry creates an attributed Command and done moots its current version", %{store: store} do
    output = capture_io(fn -> Aiur.AsksCLI.rpc(["ask", "Approve release?", "--body", "Release context", "--blocking", "--urgency", "high"], "caller-executor", decision_store: store) end)
    assert [_, id] = Regex.run(~r/Created (dec_[0-9a-f]{16}) \(BLOCKING\)\./, output)
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert {:ok, decision} = DecisionStore.get(id, store)
    assert decision.question == "Approve release?"
    assert decision.context.long_context_markdown == "Release context"
    assert decision.blocking
    assert decision.urgency == :high
    assert decision.requester.executor_id == "caller-executor"
    assert decision.authority == :human_required
    assert decision.options == []

    assert {:ok, %{decision: enriched}} =
             DecisionStore.enrich(id, %{context: %{short_summary: "Updated context"}}, [expected_version: decision.version, actor: %{kind: :supervisor, id: "supervising-agent"}], store)

    assert enriched.version > decision.version
    output = capture_io(fn -> Aiur.AsksCLI.rpc(["ask", "--done", id], "caller-executor", decision_store: store) end)
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert {:ok, decision} = DecisionStore.get(id, store)
    assert decision.decision_status == :moot
  end

  test "missing Command errors reach the RPC caller", %{store: store} do
    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          Aiur.AsksCLI.rpc(["ask", "--done", "dec_0123456789abcdef"], "caller", decision_store: store)
        end)
      end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur ask: :not_found"
    assert output =~ "__AIUR_CONTROL_EXIT__:2"
  end

  test "moot errors reach the RPC caller", %{store: store} do
    output = capture_io(fn -> Aiur.AsksCLI.rpc(["ask", "Approve release?"], "caller", decision_store: store) end)
    assert [_, id] = Regex.run(~r/Created (dec_[0-9a-f]{16})\./, output)

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          Aiur.AsksCLI.rpc(["ask", "--done", id], "caller", decision_store: store, moot_fun: fn _, _, _, _ -> {:error, :not_found} end)
        end)
      end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: failed to moot Command (:not_found)"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "unexpected RPC failure returns an error and exit marker", %{store: store} do
    output = capture_io(fn -> Aiur.AsksCLI.rpc(["ask", "Approve release?"], "caller", decision_store: store) end)
    assert [_, id] = Regex.run(~r/Created (dec_[0-9a-f]{16})\./, output)

    output =
      capture_io(fn ->
        Aiur.AsksCLI.rpc(["ask", "--done", id], "caller", decision_store: store, moot_fun: fn _, _, _, _ -> raise "moot crashed" end)
      end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: ask query failed (moot crashed)"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end
end

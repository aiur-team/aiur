defmodule Aiur.AgentRunner.ModelLabelRefreshTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.ModelLabelRefresh
  alias Aiur.CodingAgent
  alias Aiur.Issue

  @claude {["opus", "sonnet", "haiku", "opus-5-5"], :discovered}

  # A catalogue the injected refresh can change, standing in for the cache
  # file every reader shares.
  defp catalogue(initial) do
    {:ok, store} = Agent.start_link(fn -> initial end)
    reader = fn backend -> Agent.get(store, &Map.get(&1, backend, {[], :discovered})) end
    {store, reader}
  end

  # Refreshes run concurrently in their own tasks, so the test pid is captured
  # here rather than read from the calling process.
  defp refreshing(store, backend, entry) do
    test = self()

    fn refreshed ->
      send(test, {:refreshed, refreshed})
      if refreshed == backend, do: Agent.update(store, &Map.put(&1, backend, entry))
      {:ok, :refreshed}
    end
  end

  describe "prepare/2" do
    test "a model newer than the cache resolves after one refresh and decides the run" do
      {store, reader} = catalogue(%{"claude" => @claude, "codex" => {["gpt-5.6-sol"], :discovered}})
      issue = %Issue{identifier: "NEW", labels: ["model:astra"]}
      refresh = refreshing(store, "codex", {["gpt-5.6-sol", "gpt-5.7-astra"], :discovered})

      assert {^issue, nil} = ModelLabelRefresh.prepare(issue, catalogue: reader, refresh: refresh)
      assert_received {:refreshed, "codex"}
      assert CodingAgent.backend_for(issue, catalogue: reader) == "codex"
      assert CodingAgent.model_for(issue, catalogue: reader) == "astra"
    end

    test "an unknown name probes each CLI once — claude and claude-repl share one probe" do
      {store, reader} = catalogue(%{"claude" => @claude, "codex" => {["gpt-5.6-sol"], :discovered}})
      issue = %Issue{identifier: "TYPO", labels: ["model:opsu"]}

      ModelLabelRefresh.prepare(issue, catalogue: reader, refresh: refreshing(store, "none", nil))

      refreshed = for {:refreshed, backend} <- Process.info(self(), :messages) |> elem(1), do: backend
      assert Enum.sort(refreshed) == ["claude", "codex"]
    end

    test "a resolvable label does not probe any CLI" do
      {_store, reader} = catalogue(%{"claude" => @claude})
      issue = %Issue{identifier: "KNOWN", labels: ["model:opus"]}

      assert {^issue, nil} = ModelLabelRefresh.prepare(issue, catalogue: reader, refresh: fn b -> flunk("probed #{b}") end)
    end

    test "an ambiguous label is not refreshed — no catalogue update can settle it" do
      {_store, reader} = catalogue(%{"claude" => {["foo"], :discovered}, "codex" => {["foo"], :discovered}})
      issue = %Issue{identifier: "AMBIG", labels: ["model:foo"]}

      assert {^issue, nil} = ModelLabelRefresh.prepare(issue, catalogue: reader, refresh: fn b -> flunk("probed #{b}") end)
    end

    test "a label that resolves late keeps an existing selection and is reported as deferred" do
      {store, reader} = catalogue(%{"claude" => @claude, "codex" => {["gpt-5.6-sol"], :discovered}})
      issue = %Issue{identifier: "PICKED", labels: ["model:astra"], selected_backend: "claude", selected_model: "sonnet"}
      refresh = refreshing(store, "codex", {["gpt-5.7-astra"], :discovered})

      assert {^issue, {"model:astra", "codex"}} = ModelLabelRefresh.prepare(issue, catalogue: reader, refresh: refresh)
      assert CodingAgent.backend_for(issue, catalogue: reader) == "claude"
    end
  end

  describe "maybe_alert/7" do
    test "an unknown name warns with the label, the cause, and the model that ran instead" do
      {_store, reader} = catalogue(%{"claude" => @claude, "codex" => {["gpt-5.6-sol"], :discovered}})
      issue = %Issue{identifier: "TYPO", labels: ["model:opsu", "complexity:3"]}

      log =
        capture_log(fn ->
          assert :ok = ModelLabelRefresh.maybe_alert(issue, "/ws", nil, "codex", "gpt-5.6-sol", nil, catalogue: reader)
        end)

      assert log =~ "`model:opsu` does not name a model"
      assert log =~ "codex gpt-5.6-sol instead"
    end

    test "a catalogue that was never read says the name could not be checked" do
      {_store, reader} = catalogue(%{"claude" => @claude, "codex" => {["gpt-5.6-sol"], :curated_only}})
      issue = %Issue{identifier: "OFFLINE", labels: ["model:astra"]}

      log =
        capture_log(fn ->
          assert :ok = ModelLabelRefresh.maybe_alert(issue, "/ws", nil, "claude", "opus", nil, catalogue: reader)
        end)

      assert log =~ "could not be checked"
      assert log =~ "codex"
      assert log =~ "claude opus instead"
    end

    test "an ambiguous name lists the prefixed forms that would settle it" do
      {_store, reader} = catalogue(%{"claude" => {["foo"], :discovered}, "codex" => {["foo"], :discovered}})
      issue = %Issue{identifier: "AMBIG", labels: ["model:foo"]}

      log =
        capture_log(fn ->
          assert :ok = ModelLabelRefresh.maybe_alert(issue, "/ws", nil, "codex", nil, nil, catalogue: reader)
        end)

      assert log =~ "`model:claude-foo` or `model:codex-foo`"
      assert log =~ "codex (its default model) instead"
    end

    test "a deferred label names the backend it will use from the next dispatch" do
      issue = %Issue{identifier: "LATE", labels: ["model:astra"]}

      log =
        capture_log(fn ->
          assert :ok = ModelLabelRefresh.maybe_alert(issue, "/ws", nil, "claude", "sonnet", {"model:astra", "codex"})
        end)

      assert log =~ "resolves to codex"
      assert log =~ "next dispatch"
    end

    test "a label that resolved stays silent" do
      {_store, reader} = catalogue(%{"claude" => @claude})
      issue = %Issue{identifier: "FINE", labels: ["model:opus"]}

      assert capture_log(fn ->
               assert :ok = ModelLabelRefresh.maybe_alert(issue, "/ws", nil, "claude", "opus", nil, catalogue: reader)
             end) == ""
    end
  end
end

defmodule Aiur.SignalLifecyclePortTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.Signal

  defmodule Sink do
    def enabled?(opts) do
      send(self(), {:enabled, opts})
      Keyword.fetch!(opts, :enabled)
    end

    def decode_codex_operation(message) do
      send(self(), {:codex, message})
      {:start, "codex-op", "mix test"}
    end

    def decode_claude_operation(message) do
      send(self(), {:claude, message})
      {:complete, "claude-op", "mix lint", :success}
    end

    def external_anchor(event) do
      send(self(), {:anchor, event})
      {:ok, %{event: "pr_merged", ticket: "42"}, "2026-10-25T12:00:00Z"}
    end

    def terminal_capture(identity, lifecycle) do
      send(self(), {:terminal, identity, lifecycle})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:aiur, :signal)

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:aiur, :signal, config)
        :error -> Application.delete_env(:aiur, :signal)
      end
    end)
  end

  test "remaining lifecycle operations forward exact arguments and results synchronously" do
    Application.put_env(:aiur, :signal, lifecycle_sink: Sink)
    opts = [enabled: true, recorder: :test_recorder]
    assert Signal.lifecycle_enabled?(opts)
    assert_received {:enabled, ^opts}
    refute Signal.lifecycle_enabled?(enabled: false)
    assert_received {:enabled, [enabled: false]}

    message = %{"id" => "operation", "command" => "private command"}
    assert {:start, "codex-op", "mix test"} = Signal.decode_codex_operation(message)
    assert_received {:codex, ^message}
    assert {:complete, "claude-op", "mix lint", :success} = Signal.decode_claude_operation(message)
    assert_received {:claude, ^message}

    event = %{topic: "ticket.42.pr.merged", source: :github}
    assert {:ok, %{event: "pr_merged", ticket: "42"}, "2026-10-25T12:00:00Z"} = Signal.external_anchor(event)
    assert_received {:anchor, ^event}

    identity = %{repo: "test/repo", number: 42}
    assert :ok = Signal.terminal_capture(identity, :completed)
    assert_received {:terminal, ^identity, :completed}
    refute_received {:terminal, _, _}
  end

  test "absent lifecycle sink silently disables reads and ignores writes" do
    for config <- [:absent, [], [lifecycle_sink: nil]] do
      if config == :absent, do: Application.delete_env(:aiur, :signal), else: Application.put_env(:aiur, :signal, config)

      assert capture_log(fn ->
               refute Signal.lifecycle_enabled?()
               refute Signal.lifecycle_enabled?(recorder: fn _, _, _ -> flunk("no sink") end)
               assert :skip = Signal.decode_codex_operation(%{})
               assert :skip = Signal.decode_claude_operation(%{})
               assert :skip = Signal.external_anchor(%{})
               assert :ok = Signal.terminal_capture(%{}, :cancelled)
               assert :ok = Signal.lifecycle("42", nil, :dispatch, :point)
               assert :ok = Signal.backend_message("42", nil, "codex", %{})
             end) == ""
    end
  end

  test "production callers depend on the signal port rather than the optional lifecycle implementation" do
    root = Path.expand("../../lib", __DIR__)
    files = Path.wildcard(Path.join(root, "**/*.ex"))
    assert files != []

    for file <- files, not String.starts_with?(Path.relative_to(file, root), "aiur/run_telemetry/") do
      refute File.read!(file) =~ "RunTelemetry.Lifecycle", file
    end
  end
end

defmodule Aiur.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Codex.CodingAgent, as: CodexAgent
  alias Aiur.Codex.Config, as: CodexConfig
  alias Aiur.CodingAgent
  alias Aiur.Issue

  defp issue(labels), do: %Issue{labels: labels}

  describe "override_backend/1 (model: tag selects backend)" do
    test "bare model:<backend> selects that backend" do
      assert CodingAgent.override_backend(issue(["model:claude"])) == "claude"
      assert CodingAgent.override_backend(issue(["model:codex"])) == "codex"
    end

    test "model:<backend>-<variant> still selects the backend" do
      assert CodingAgent.override_backend(issue(["model:claude-opus-4-8"])) == "claude"
    end

    test "a hyphenated backend is resolved whole, not split into backend+variant" do
      # `claude-repl` must win over the shorter `claude` so its trailing
      # `repl` segment is not mistaken for a model variant.
      assert CodingAgent.override_backend(issue(["model:claude-repl"])) == "claude-repl"
      assert CodingAgent.model_for(issue(["model:claude-repl"])) == nil
    end

    test "a hyphenated backend still pins a trailing variant" do
      assert CodingAgent.override_backend(issue(["model:claude-repl-opus-4-8"])) == "claude-repl"
      assert CodingAgent.model_for(issue(["model:claude-repl-opus-4-8"])) == "opus-4-8"
    end

    test "unknown backend in a model: tag is ignored" do
      assert CodingAgent.override_backend(issue(["model:bogus"])) == nil
      assert CodingAgent.override_backend(issue(["model:bogus-x"])) == nil
    end

    test "no model: tag yields nil" do
      assert CodingAgent.override_backend(issue(["complexity:5", "agent:todo"])) == nil
    end
  end

  describe "model:claude-remote alias (forces RC, resolves to claude-repl)" do
    test "the alias resolves whole to the claude-repl backend, no variant" do
      assert CodingAgent.override_backend(issue(["model:claude-remote"])) == "claude-repl"
      assert CodingAgent.model_for(issue(["model:claude-remote"])) == nil
    end

    test "the alias is not mis-split into backend claude + variant remote" do
      refute CodingAgent.override_backend(issue(["model:claude-remote"])) == "claude"
      refute CodingAgent.model_for(issue(["model:claude-remote"])) == "remote"
    end

    test "remote_control_forced? is true only when the alias label is present" do
      assert CodingAgent.remote_control_forced?(issue(["model:claude-remote"]))
      refute CodingAgent.remote_control_forced?(issue(["model:claude-repl"]))
      refute CodingAgent.remote_control_forced?(issue(["model:claude"]))
      refute CodingAgent.remote_control_forced?(issue(["complexity:5"]))
    end

    test "the alias label is auto-seeded" do
      assert "model:claude-remote" in CodingAgent.override_labels()
    end

    test "an alias-variant label pins the model through the alias" do
      assert CodingAgent.override_backend(issue(["model:claude-remote-sonnet"])) == "claude-repl"
      assert CodingAgent.model_for(issue(["model:claude-remote-sonnet"])) == "sonnet"
    end

    test "an alias-variant label still forces remote control" do
      assert CodingAgent.remote_control_forced?(issue(["model:claude-remote-sonnet"]))
      assert CodingAgent.remote_control_forced?(issue(["model:claude-remote-opus-4-8"]))
      refute CodingAgent.remote_control_forced?(issue(["model:claude-sonnet"]))
    end
  end

  describe "backend_for/1 precedence (override beats routing/default)" do
    test "a model: override wins over a complexity: label that would route elsewhere" do
      assert CodingAgent.backend_for(issue(["model:claude", "complexity:5"])) == "claude"
      assert CodingAgent.backend_for(issue(["model:codex", "complexity:5"])) == "codex"
    end

    test "first matching model: label wins when several are present" do
      assert CodingAgent.override_backend(issue(["model:claude", "model:codex"])) == "claude"
      assert CodingAgent.override_backend(issue(["model:codex", "model:claude"])) == "codex"
    end
  end

  describe "override silent-drop boundaries (intentional fallthrough)" do
    test "a disallowed variant charset drops the whole override" do
      assert CodingAgent.override_backend(issue(["model:claude-opus_4"])) == nil
      assert CodingAgent.model_for(issue(["model:claude-opus_4"])) == nil
    end

    test "a capitalized backend is not recognized" do
      assert CodingAgent.override_backend(issue(["model:Claude"])) == nil
    end
  end

  describe "model_for/1 (3-layer model: tag)" do
    test "broadest model:<backend> pins no model (backend default)" do
      assert CodingAgent.model_for(issue(["model:claude"])) == nil
      assert CodingAgent.model_for(issue(["model:codex"])) == nil
    end

    test "family layer pins the family string" do
      assert CodingAgent.model_for(issue(["model:claude-opus"])) == "opus"
      assert CodingAgent.model_for(issue(["model:claude-sonnet"])) == "sonnet"
      assert CodingAgent.model_for(issue(["model:claude-haiku"])) == "haiku"
    end

    test "specific layer pins the exact version string" do
      assert CodingAgent.model_for(issue(["model:claude-opus-4-8"])) == "opus-4-8"
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.5"])) == "gpt-5.5"
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.4-mini"])) == "gpt-5.4-mini"
    end

    test "no model: tag pins nothing" do
      assert CodingAgent.model_for(issue(["complexity:4"])) == nil
    end
  end

  describe "complexity_level/1" do
    test "highest well-formed complexity wins" do
      assert CodingAgent.complexity_level(issue(["complexity:2", "complexity:5"])) == 5
    end

    test "absent or malformed complexity yields nil" do
      assert CodingAgent.complexity_level(issue(["agent:todo"])) == nil
      assert CodingAgent.complexity_level(issue(["complexity:high"])) == nil
    end
  end

  describe "registry dispatch" do
    test "known_backends comes from the registry" do
      assert Enum.sort(CodingAgent.known_backends()) == ["claude", "claude-repl", "codex"]
    end

    test "adapter and transcript_module resolve per backend" do
      assert CodingAgent.adapter("claude") == Aiur.Claude.CodingAgent
      assert CodingAgent.adapter("codex") == Aiur.Codex.CodingAgent
      assert CodingAgent.adapter("claude-repl") == Aiur.Claude.ReplAgent
      assert CodingAgent.transcript_module("claude") == Aiur.Claude.Transcript
      assert CodingAgent.transcript_module("codex") == Aiur.Codex.Transcript
      assert CodingAgent.transcript_module("claude-repl") == Aiur.Claude.Transcript
    end

    test "delivery-policy defaults come from the registry" do
      assert CodingAgent.can_interrupt?("codex")
      assert CodingAgent.safe_checkpoints("codex") == [:notification, :tool_result]
      assert CodingAgent.safe_checkpoints("claude") == [:notification]
      # The REPL holds nothing at a checkpoint, but Ctrl+C to its pane is
      # an out-of-band interrupt, so it advertises the capability.
      assert CodingAgent.can_interrupt?("claude-repl")
      assert CodingAgent.safe_checkpoints("claude-repl") == []
    end

    test "immediate_delivery? is true only for the REPL backend" do
      assert CodingAgent.immediate_delivery?("claude-repl")
      refute CodingAgent.immediate_delivery?("claude")
      refute CodingAgent.immediate_delivery?("codex")
      refute CodingAgent.immediate_delivery?("opencode")
    end

    test "unknown backend fails loud" do
      assert_raise ArgumentError, ~r/unknown coding-agent backend/, fn ->
        CodingAgent.adapter("opencode")
      end
    end

    test "remote_control? is true for claude, false for codex" do
      assert CodingAgent.remote_control?("claude")
      assert CodingAgent.remote_control?("claude-repl")
      refute CodingAgent.remote_control?("codex")
    end

    test "remote_control? is false for an unknown backend" do
      refute CodingAgent.remote_control?("opencode")
    end

    test "override_labels seeds all three tag layers per backend" do
      labels = CodingAgent.override_labels()
      assert "model:claude" in labels
      assert "model:claude-opus" in labels
      assert "model:claude-opus-4-8" in labels
      assert "model:codex" in labels
    end

    test "override_labels seeds bare haiku and cheaper codex variants" do
      labels = CodingAgent.override_labels()
      assert "model:claude-haiku" in labels
      assert "model:codex-gpt-5.4" in labels
      assert "model:codex-gpt-5.5-mini" in labels
      assert "model:codex-gpt-5.4-mini" in labels
    end
  end

  describe "send_operator_message/2" do
    test "Codex adapter writes a turn/start frame with a fresh request id" do
      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace",
        approval_policy: "untrusted",
        turn_sandbox_policy: %{"mode" => "read-only"}
      }

      assert {:ok, request_id} =
               CodexAgent.send_operator_message(session, %{kind: :text, body: "hello agent"})

      assert is_integer(request_id) and request_id > 0

      frame = read_one_frame(port)
      assert frame["method"] == "turn/start"
      assert frame["id"] == request_id
      assert frame["params"]["threadId"] == "thread-abc"
      assert frame["params"]["input"] == [%{"type" => "text", "text" => "hello agent"}]
      assert frame["params"]["cwd"] == "/tmp/workspace"
      assert frame["params"]["approvalPolicy"] == "untrusted"

      close_port(port)
    end

    test "Codex adapter returns {:error, :invalid_session} for malformed session" do
      assert {:error, :invalid_session} =
               CodexAgent.send_operator_message(%{}, %{kind: :text, body: "hi"})
    end

    test "Codex adapter returns {:error, :port_closed} when port is dead" do
      port = open_cat_port()
      close_port(port)

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace",
        approval_policy: "untrusted",
        turn_sandbox_policy: %{}
      }

      assert {:error, :port_closed} =
               CodexAgent.send_operator_message(session, %{kind: :text, body: "hi"})
    end

    test "Claude adapter writes a turn/start frame with a fresh request id" do
      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-xyz",
        workspace: "/tmp/workspace"
      }

      assert {:ok, request_id} =
               ClaudeAgent.send_operator_message(session, %{kind: :text, body: "hello claude"})

      assert is_integer(request_id) and request_id > 0

      frame = read_one_frame(port)
      assert frame["method"] == "turn/start"
      assert frame["id"] == request_id
      assert frame["params"]["threadId"] == "thread-xyz"
      assert frame["params"]["input"] == [%{"type" => "text", "text" => "hello claude"}]

      close_port(port)
    end

    test "Claude adapter pins the session's model into the turn/start frame" do
      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-xyz",
        workspace: "/tmp/workspace",
        model: "opus-4-8"
      }

      assert {:ok, _request_id} =
               ClaudeAgent.send_operator_message(session, %{kind: :text, body: "hello claude"})

      frame = read_one_frame(port)
      assert frame["params"]["model"] == "opus-4-8"

      close_port(port)
    end

    test "Claude adapter returns {:error, :invalid_session} for malformed session" do
      assert {:error, :invalid_session} =
               ClaudeAgent.send_operator_message(%{}, %{kind: :text, body: "hi"})
    end
  end

  describe "codex_command/1 model splice" do
    test "nil model leaves the configured command unchanged" do
      assert CodexAgent.codex_command_for_test(nil) == CodexConfig.command()
    end

    test "a model variant is appended as a single-quoted --config token" do
      command = CodexAgent.codex_command_for_test("gpt-5.5")
      assert command == CodexConfig.command() <> " --config 'model=\"gpt-5.5\"'"
      assert String.ends_with?(command, "--config 'model=\"gpt-5.5\"'")
    end
  end

  describe "unretryable codex error detection" do
    test "willRetry:false inside params trips the unretryable path" do
      payload = %{"method" => "error", "params" => %{"willRetry" => false, "message" => "usageLimitExceeded"}}
      assert CodexAgent.unretryable_codex_error_for_test(payload)
      assert CodexAgent.codex_error_reason_for_test(payload, "error") == "error: usageLimitExceeded"
    end

    test "willRetry:false at the notification root also trips it" do
      assert CodexAgent.unretryable_codex_error_for_test(%{"willRetry" => false})
    end

    test "snake_case will_retry:false is honored" do
      assert CodexAgent.unretryable_codex_error_for_test(%{"params" => %{"will_retry" => false}})
    end

    test "willRetry:true is retryable (continues, not a hard failure)" do
      refute CodexAgent.unretryable_codex_error_for_test(%{"params" => %{"willRetry" => true}})
    end

    test "absent willRetry is retryable" do
      refute CodexAgent.unretryable_codex_error_for_test(%{"params" => %{"message" => "transient blip"}})
    end

    test "reason falls back to the method when no detail field is present" do
      assert CodexAgent.codex_error_reason_for_test(%{"params" => %{"willRetry" => false}}, "task/error") == "task/error"
    end
  end

  defp open_cat_port do
    Port.open(
      {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
      [:binary, :exit_status, {:line, 64_000}]
    )
  end

  defp read_one_frame(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Jason.decode!(line)

      {^port, {:data, line}} when is_binary(line) ->
        line
        |> String.trim_trailing()
        |> Jason.decode!()
    after
      1_000 -> flunk("no frame read from port within 1s")
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end

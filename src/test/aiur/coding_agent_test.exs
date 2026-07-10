defmodule Aiur.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Codex.AppServerPort
  alias Aiur.Codex.CodingAgent, as: CodexAgent
  alias Aiur.Codex.Config, as: CodexConfig
  alias Aiur.Codex.NotificationPolicy
  alias Aiur.CodingAgent
  alias Aiur.Issue

  defp issue(labels), do: %Issue{labels: labels}

  describe "select_for_dispatch/2" do
    test "uses the first configured, available fallback from an ordered list" do
      assert {:ok, %Issue{selected_backend: "claude"}} =
               CodingAgent.select_for_dispatch(issue([]),
                 backends: ["unconfigured", "claude", "codex"],
                 configured_backends: ["claude"]
               )
    end

    test "keeps an explicit backend selection unchanged" do
      explicit = %Issue{labels: ["model:codex"]}

      assert {:ok, ^explicit} =
               CodingAgent.select_for_dispatch(explicit,
                 backends: ["claude"],
                 configured_backends: ["claude"]
               )
    end

    test "reports all configured candidates when none is available" do
      state = %{
        "backends" => %{"claude" => %{"limited" => true, "reset_at" => "2999-01-01T00:00:00Z"}}
      }

      assert {:all_limited, ["claude"]} =
               CodingAgent.select_for_dispatch(issue([]),
                 backends: ["claude", "codex"],
                 configured_backends: ["claude"],
                 state: state
               )
    end

    test "selects codex after claude is marked limited" do
      state = %{
        "backends" => %{"claude" => %{"limited" => true, "reset_at" => "2999-01-01T00:00:00Z"}}
      }

      assert {:ok, %Issue{selected_backend: "codex"}} =
               CodingAgent.select_for_dispatch(issue([]),
                 backends: ["claude", "codex"],
                 configured_backends: ["claude", "codex"],
                 state: state
               )
    end
  end

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

  describe "model:remote is a remote flag, not a backend selector" do
    test "the bare alias selects no backend and pins no model" do
      assert CodingAgent.override_backend(issue(["model:remote"])) == nil
      assert CodingAgent.model_for(issue(["model:remote"])) == nil
    end

    test "a companion model tag picks backend+model; the alias only forces RC" do
      issue = issue(["model:claude-haiku", "model:remote"])
      assert CodingAgent.backend_for(issue) == "claude"
      assert CodingAgent.model_for(issue) == "haiku"
      assert CodingAgent.remote_control_forced?(issue)
    end

    test "the alias is skipped regardless of label order" do
      reordered = issue(["model:remote", "model:claude-haiku"])
      assert CodingAgent.backend_for(reordered) == "claude"
      assert CodingAgent.model_for(reordered) == "haiku"
    end

    test "remote_control_forced? is true only when the alias label is present" do
      assert CodingAgent.remote_control_forced?(issue(["model:remote"]))
      refute CodingAgent.remote_control_forced?(issue(["model:claude-repl"]))
      refute CodingAgent.remote_control_forced?(issue(["model:claude"]))
      refute CodingAgent.remote_control_forced?(issue(["complexity:5"]))
    end

    test "an alias-variant label is flag-only (no backend/model) but still forces RC" do
      assert CodingAgent.override_backend(issue(["model:remote-sonnet"])) == nil
      assert CodingAgent.model_for(issue(["model:remote-sonnet"])) == nil
      assert CodingAgent.remote_control_forced?(issue(["model:remote-sonnet"]))
      assert CodingAgent.remote_control_forced?(issue(["model:remote-opus-4-8"]))
      refute CodingAgent.remote_control_forced?(issue(["model:claude-sonnet"]))
    end

    test "the alias label is auto-seeded" do
      assert "model:remote" in CodingAgent.override_labels()
    end

    test "routing_remote? is false with no complexity label (global config untouched)" do
      refute CodingAgent.routing_remote?(issue(["agent:todo"]))
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
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.6-sol"])) == "gpt-5.6-sol"
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.6-terra"])) == "gpt-5.6-terra"
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.6-luna"])) == "gpt-5.6-luna"
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

    test "effort vocabulary comes from the registry" do
      assert CodingAgent.efforts("codex") == ["none", "low", "medium", "high", "xhigh", "max"]
      assert CodingAgent.efforts("claude") == []
      assert CodingAgent.efforts("claude-repl") == ["low", "medium", "high", "xhigh", "max"]
      assert CodingAgent.efforts("opencode") == []
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

    test "resumable? is true for codex and claude-repl, false for headless claude" do
      # codex app-server exposes thread/resume against an on-disk rollout, and the
      # claude REPL drives the `claude` CLI directly so it can `--resume` the
      # on-disk transcript jsonl — both rejoin a prior session after a restart.
      # The headless claude app-server only rehydrates an in-memory thread map
      # (lost on restart) and exposes no disk-resume seed, so it degrades to a
      # clean start (#378/#613).
      assert CodingAgent.resumable?("codex")
      assert CodingAgent.resumable?("claude-repl")
      refute CodingAgent.resumable?("claude")
    end

    test "resumable? is false for an unknown backend" do
      refute CodingAgent.resumable?("opencode")
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
      assert "model:codex-gpt-5.6-sol" in labels
      assert "model:codex-gpt-5.6-terra" in labels
      assert "model:codex-gpt-5.6-luna" in labels
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

  describe "codex_command/2 model and effort splice" do
    test "nil model leaves the configured command unchanged" do
      assert AppServerPort.codex_command_for_test(nil) == CodexConfig.command()
    end

    test "a model variant is appended as a single-quoted --config token" do
      command = AppServerPort.codex_command_for_test("gpt-5.5")
      assert command == CodexConfig.command() <> " --config 'model=\"gpt-5.5\"'"
      assert String.ends_with?(command, "--config 'model=\"gpt-5.5\"'")
    end

    test "an effort override is appended after model so it beats command defaults" do
      command = AppServerPort.codex_command_for_test("gpt-5.5", "high")

      assert command ==
               CodexConfig.command() <>
                 " --config 'model=\"gpt-5.5\"' --config 'model_reasoning_effort=\"high\"'"
    end

    test "config values are shell escaped as single arguments" do
      command = AppServerPort.codex_command_for_test("gpt'5.5", "high")

      assert command ==
               CodexConfig.command() <>
                 " --config 'model=\"gpt'\"'\"'5.5\"' --config 'model_reasoning_effort=\"high\"'"
    end
  end

  describe "unretryable codex error detection" do
    test "willRetry:false inside params trips the unretryable path" do
      payload = %{
        "method" => "error",
        "params" => %{"willRetry" => false, "message" => "usageLimitExceeded"}
      }

      assert NotificationPolicy.unretryable_codex_error?(payload)

      assert NotificationPolicy.codex_error_reason(payload, "error") ==
               "error: usageLimitExceeded"
    end

    test "willRetry:false at the notification root also trips it" do
      assert NotificationPolicy.unretryable_codex_error?(%{"willRetry" => false})
    end

    test "snake_case will_retry:false is honored" do
      assert NotificationPolicy.unretryable_codex_error?(%{"params" => %{"will_retry" => false}})
    end

    test "willRetry:true is retryable (continues, not a hard failure)" do
      refute NotificationPolicy.unretryable_codex_error?(%{"params" => %{"willRetry" => true}})
    end

    test "absent willRetry is retryable" do
      refute NotificationPolicy.unretryable_codex_error?(%{
               "params" => %{"message" => "transient blip"}
             })
    end

    test "reason falls back to the method when no detail field is present" do
      assert NotificationPolicy.codex_error_reason(
               %{"params" => %{"willRetry" => false}},
               "task/error"
             ) == "task/error"
    end

    test "reason reaches a codexErrorInfo detail instead of the bare method" do
      payload = %{"params" => %{"willRetry" => false, "codexErrorInfo" => "usageLimitExceeded"}}

      assert NotificationPolicy.codex_error_reason(payload, "error") ==
               "error: usageLimitExceeded"
    end

    test "reason reaches a nested error.message detail" do
      payload = %{"params" => %{"error" => %{"message" => "overloaded"}}}

      assert NotificationPolicy.codex_error_reason(payload, "task/error") ==
               "task/error: overloaded"
    end
  end

  describe "codex usage-limit (quota exhausted) detection" do
    test "a usageLimitExceeded error is detected as a quota pause" do
      payload = %{
        "method" => "error",
        "params" => %{
          "willRetry" => false,
          "codexErrorInfo" => "usageLimitExceeded",
          "message" => "You've hit your usage limit. Purchase more credits or try again at 11:43 PM."
        }
      }

      assert NotificationPolicy.usage_limit_exceeded?(payload)
    end

    test "an ordinary willRetry:false error is not a quota pause" do
      payload = %{
        "method" => "error",
        "params" => %{"willRetry" => false, "message" => "bwrap: sandbox refused"}
      }

      refute NotificationPolicy.usage_limit_exceeded?(payload)
    end

    test "the reset time is extracted from the human message" do
      payload = %{
        "params" => %{
          "message" => "You've hit your usage limit. Purchase more credits or try again at 11:43 PM."
        }
      }

      assert NotificationPolicy.usage_limit_reset_hint(payload) == "11:43 PM"
    end

    test "the reset hint is nil when no try-again phrase is present" do
      refute NotificationPolicy.usage_limit_reset_hint(%{
               "params" => %{"message" => "usageLimitExceeded"}
             })
    end

    test "a quota error routes to a pause carrying the reset hint, not an unretryable error" do
      payload = %{
        "method" => "error",
        "params" => %{
          "willRetry" => false,
          "codexErrorInfo" => "usageLimitExceeded",
          "message" => "You've hit your usage limit. Purchase more credits or try again at 11:43 PM."
        }
      }

      assert NotificationPolicy.codex_quota_exhausted?("error", payload)
      pause = NotificationPolicy.usage_limit_pause(payload, "error")
      assert pause.kind == :usage_limit_exhausted
      assert pause.reset_hint == "11:43 PM"
      # The pause carries the real backend detail, never the opaque bare "error".
      assert pause.reason =~ "usage limit"
      refute pause.reason == "error"
    end

    test "an ordinary unretryable error still routes to a turn_unretryable error, not a pause" do
      payload = %{
        "method" => "error",
        "params" => %{"willRetry" => false, "message" => "bwrap: sandbox refused"}
      }

      refute NotificationPolicy.codex_quota_exhausted?("error", payload)

      assert NotificationPolicy.codex_error_method?("error") and
               NotificationPolicy.unretryable_codex_error?(payload)

      assert NotificationPolicy.codex_error_reason(payload, "error") ==
               "error: bwrap: sandbox refused"
    end

    test "a retryable error mentioning a usage limit is NOT a quota pause" do
      # willRetry:true means codex will retry; pausing would strand the agent
      # (no auto-resume), so a transient "usage limit" mention must not pause.
      payload = %{
        "method" => "error",
        "params" => %{"willRetry" => true, "message" => "approaching usage limit, retrying"}
      }

      refute NotificationPolicy.codex_quota_exhausted?("error", payload)
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

  describe "Aiur.CodingAgent.Backend wiring" do
    test "every registry adapter implements the behaviour" do
      for {backend, entry} <- CodingAgent.backends() do
        behaviours =
          entry.adapter.module_info(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert Aiur.CodingAgent.Backend in behaviours,
               "adapter #{inspect(entry.adapter)} for #{inspect(backend)} " <>
                 "must declare @behaviour Aiur.CodingAgent.Backend"
      end
    end

    test "remote_transport/1 returns the declared RC transport" do
      assert CodingAgent.remote_transport("claude") == "claude-repl"
      assert CodingAgent.remote_transport("claude-repl") == "claude-repl"
      assert CodingAgent.remote_transport("codex") == "codex"
      assert CodingAgent.remote_transport("nonexistent") == "nonexistent"
    end

    test "fallback_backend/1 returns the declared spawn-failure fallback" do
      assert CodingAgent.fallback_backend("claude-repl") == "claude"
      assert CodingAgent.fallback_backend("claude") == nil
      assert CodingAgent.fallback_backend("codex") == nil
      assert CodingAgent.fallback_backend("nonexistent") == nil
    end
  end

  describe "rc_display_tail?/1" do
    test "only claude-repl feeds the RC display tailer" do
      assert CodingAgent.rc_display_tail?("claude-repl")
      refute CodingAgent.rc_display_tail?("claude")
      refute CodingAgent.rc_display_tail?("codex")
      refute CodingAgent.rc_display_tail?("mystery")
    end
  end

  describe "runtime_report/1" do
    test "claude-repl reports its pane runtime" do
      assert CodingAgent.runtime_report("claude-repl") == :repl_pane
    end

    test "headless claude reports its wrapper pid" do
      assert CodingAgent.runtime_report("claude") == :headless_wrapper
    end

    test "codex and unknown backends report nothing" do
      assert CodingAgent.runtime_report("codex") == nil
      assert CodingAgent.runtime_report("mystery") == nil
    end
  end
end

defmodule Aiur.Codex.LivenessProbeTest do
  # Regression for #7465: a quiet Codex app-server held a worker slot until the
  # 60-minute stall watchdog fired. Every case here drives a real
  # `CodingAgent.run_turn/4` against a fake app-server, so the periodic probe is
  # exercised through the production wiring instead of hand-built loop state:
  # `loop_state_extras/1` arms the first timer, `AppServer.TurnLoop` dispatches
  # `:codex_liveness_probe`, and an answered read settles the probe. Deleting the
  # `LivenessProbe.schedule/2` call in `loop_state_extras/1` or the
  # `:codex_liveness_probe` clause in `AppServer.TurnLoop.receive_messages/2`
  # makes each case below end in `{:error, :turn_timeout}` instead of its
  # asserted result.
  use Aiur.TestSupport

  alias Aiur.Codex.CodingAgent, as: CodexAgent
  alias Aiur.Codex.{LivenessProbe, SessionRecovery}

  @thread "01a0b3b2-f413-7bf1-a724-c492e3c9be3c"
  @observed_at ~U[2026-09-18 09:20:37Z]
  # The rollout's rate-limit snapshot resets 3 d 16 h 5 min 48 s after the
  # refusal: resetsAt 1790040385. Derive the epoch from @observed_at so the
  # time-bomb checker's 35-day date shift moves it with the ISO fixture instead
  # of leaving it 35 days away (#7549).
  @reset_after_seconds 317_148
  @reset_at_time DateTime.add(@observed_at, @reset_after_seconds, :second)
  @reset_at DateTime.to_iso8601(@reset_at_time)
  @resets_at_epoch DateTime.to_unix(@reset_at_time)
  @banner "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 21st, 2026 6:26 PM."
  # Production arms the probe every 60_000 ms. The injected interval only
  # shortens the wait so a silent server is caught inside a test-sized window.
  @probe_interval_ms 200
  @quick_turns_interval_ms 2_000
  # Above the 5_000 ms app-server read timeout the probe waits for an answer, so
  # a silent server's recoverable probe timeout stays distinguishable from the
  # turn's own backstop.
  @turn_timeout_ms 20_000
  # Eight streamed deltas 150 ms apart: long enough that a healthy turn crosses
  # several probe intervals and is proven not to be killed by one.
  @stream_deltas 8
  @stream_gap "0.15"

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-codex-liveness-probe")
    workspace = Path.join(Config.workspace_root(), "KHA-LIVENESS")
    File.mkdir_p!(root)
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root, workspace: workspace}
  end

  test "a silent app-server with an exhausted window pauses as a usage limit", ctx do
    %{root: root} = ctx
    trace = Path.join(root, "codex.trace")
    session = start_agent(ctx, silent_script(trace, 100))
    test_pid = self()

    started = System.monotonic_time(:millisecond)
    assert {:paused, pause} = CodexAgent.run_turn(session, "quiet", issue(), on_message: forward_to(test_pid))
    elapsed = System.monotonic_time(:millisecond) - started

    assert pause.kind == :usage_limit_exhausted
    assert pause.reset_at == @reset_at
    refute_received {:agent_message, :turn_ended_with_error}
    # Caught in seconds: neither the 20 s turn backstop nor the 60-minute stall
    # watchdog had to fire.
    assert elapsed < @turn_timeout_ms
    assert elapsed < 10_000
  end

  test "a silent app-server with allowance left ends the turn as a recoverable probe timeout", ctx do
    %{root: root} = ctx
    trace = Path.join(root, "codex.trace")
    session = start_agent(ctx, silent_script(trace, 28))
    test_pid = self()

    started = System.monotonic_time(:millisecond)

    assert {:error, {:response_timeout, :codex_liveness_probe, _state}} =
             CodexAgent.run_turn(session, "quiet", issue(), on_message: forward_to(test_pid))

    elapsed = System.monotonic_time(:millisecond) - started

    # The probe really sent its read and the server never answered it.
    assert [_read | _rest] = probe_reads(trace)
    assert SessionRecovery.recoverable?({:response_timeout, :codex_liveness_probe, %{}})
    assert_received {:agent_message, :turn_ended_with_error}
    # The bounded read deadline fired first; the turn backstop did not.
    assert elapsed >= LivenessProbe.probe_timeout_ms()
    assert elapsed < @turn_timeout_ms
  end

  test "an app-server that answers the probe and keeps streaming finishes the turn", ctx do
    %{root: root} = ctx
    trace = Path.join(root, "codex.trace")
    session = start_agent(ctx, streaming_script(trace))
    test_pid = self()

    started = System.monotonic_time(:millisecond)
    assert {:ok, result} = CodexAgent.run_turn(session, "slow but healthy", issue(), on_message: forward_to(test_pid))
    elapsed = System.monotonic_time(:millisecond) - started

    assert result.result == :turn_completed
    refute_received {:agent_message, :turn_ended_with_error}
    # The server answered every read it received, so the turn crossed several
    # probe intervals and was not killed by one.
    assert [_, _ | _rest] = probe_reads(trace)
    assert elapsed >= 1_000
    assert elapsed < @turn_timeout_ms
  end

  test "an app-server that refuses the probe read with a usage-limit error pauses", ctx do
    %{root: root} = ctx
    trace = Path.join(root, "codex.trace")
    session = start_agent(ctx, refusing_script(trace))
    test_pid = self()

    assert {:paused, pause} = CodexAgent.run_turn(session, "quiet", issue(), on_message: forward_to(test_pid))

    # The snapshot still showed allowance, so only the read's error could have
    # classified this as a usage limit.
    assert pause.kind == :usage_limit_exhausted
    assert pause.reason =~ "reported usage exhaustion"
    assert pause.reset_hint == nil
    refute_received {:agent_message, :turn_ended_with_error}
  end

  # Regression for #7963: a completed turn returns `{:ok, :turn_completed}`, not
  # its loop state, so its probe timer was never cancelled. Each finished turn
  # left a `:codex_liveness_probe` message for the next turn on the same runner;
  # two of them made the next turn send a read and immediately count it as
  # unanswered, killing a healthy session within milliseconds of turn start.
  test "probe timers from finished turns cannot time out a later turn", ctx do
    %{root: root} = ctx
    trace = Path.join(root, "codex.trace")
    # Both quick turns must finish before either one's timer fires, so neither
    # timer is consumed by the second turn instead of reaching the third.
    session = ctx |> start_agent(instant_turn_script(trace)) |> Map.put(:liveness_probe_interval_ms, @quick_turns_interval_ms)
    test_pid = self()

    for _turn <- 1..2 do
      assert {:ok, %{result: :turn_completed}} =
               CodexAgent.run_turn(session, "quick", issue(), on_message: forward_to(test_pid))
    end

    # Timers fire in deadline order, so once this later one arrives every timer
    # the finished turns armed has already fired into this mailbox.
    Process.send_after(self(), :earlier_probe_timers_fired, @quick_turns_interval_ms * 2)
    assert_receive :earlier_probe_timers_fired, @quick_turns_interval_ms * 5

    assert {:ok, %{result: :turn_completed}} =
             CodexAgent.run_turn(session, "quick", issue(), on_message: forward_to(test_pid))

    refute_received {:agent_message, :turn_ended_with_error}
  end

  defp issue do
    %Issue{id: "15", identifier: "15", title: "KHA-106", state: "In Progress", selected_backend: "codex"}
  end

  defp forward_to(test_pid) do
    fn message -> send(test_pid, {:agent_message, message.event}) end
  end

  defp start_agent(ctx, script) do
    binary = Path.join(ctx.root, "fake-codex")
    File.write!(binary, script)
    File.chmod!(binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      command: "#{binary} app-server",
      agent_turn_timeout_ms: @turn_timeout_ms
    )

    {:ok, session} = CodexAgent.start_session(ctx.workspace, clock: fn -> @observed_at end)
    on_exit(fn -> CodexAgent.stop_session(session) end)

    # The interval is the only value the session carries for the probe; arming,
    # dispatching and settling the timer all run in production code.
    Map.put(session, :liveness_probe_interval_ms, @probe_interval_ms)
  end

  defp probe_reads(trace) do
    case File.read(trace) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.contains?(&1, "account/rateLimits/read"))

      {:error, _reason} ->
        []
    end
  end

  # A server that starts the turn, reports its rate-limit window and then goes
  # silent: it reads the probe's request and never answers it.
  defp silent_script(trace, used_percent) do
    """
    #!/bin/sh
    #{handshake_cases(trace)}
      *'"method":"turn/start"'*)
        rid=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        printf '{"id":%s,"result":{"turn":{"id":"turn-1","status":"inProgress","items":[]}}}\\n' "$rid"
        printf '%s\\n' '#{turn_started_frame()}'
        printf '%s\\n' '#{rate_limits_frame(used_percent)}'
        ;;
    esac
    done
    """
  end

  # A server that starts the turn and then keeps streaming while answering every
  # probe read with an allowance-left snapshot.
  defp streaming_script(trace) do
    """
    #!/bin/sh
    #{handshake_cases(trace)}
      *'"method":"turn/start"'*)
        rid=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        printf '{"id":%s,"result":{"turn":{"id":"turn-1","status":"inProgress","items":[]}}}\\n' "$rid"
        printf '%s\\n' '#{turn_started_frame()}'
        printf '%s\\n' '#{rate_limits_frame(28)}'
        (
          for _ in #{Enum.join(1..@stream_deltas, " ")}; do
            sleep #{@stream_gap}
            printf '%s\\n' '#{delta_frame()}'
          done
          printf '%s\\n' '#{completed_frame()}'
        ) &
        ;;
      *'"method":"account/rateLimits/read"'*)
        case "$line" in
          *'"id":6'*) printf '%s\\n' '#{probe_answer_frame(28)}' ;;
        esac
        ;;
    esac
    done
    wait
    """
  end

  # A healthy server whose turns complete as soon as they start and which answers
  # every probe read.
  defp instant_turn_script(trace) do
    """
    #!/bin/sh
    #{handshake_cases(trace)}
      *'"method":"turn/start"'*)
        rid=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        printf '{"id":%s,"result":{"turn":{"id":"turn-1","status":"inProgress","items":[]}}}\\n' "$rid"
        printf '%s\\n' '#{turn_started_frame()}'
        printf '%s\\n' '#{completed_frame()}'
        ;;
      *'"method":"account/rateLimits/read"'*)
        case "$line" in
          *'"id":6'*) printf '%s\\n' '#{probe_answer_frame(28)}' ;;
        esac
        ;;
    esac
    done
    """
  end

  # A server that reports allowance left and then refuses the probe read with the
  # account usage-limit error.
  defp refusing_script(trace) do
    """
    #!/bin/sh
    #{handshake_cases(trace)}
      *'"method":"turn/start"'*)
        rid=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        printf '{"id":%s,"result":{"turn":{"id":"turn-1","status":"inProgress","items":[]}}}\\n' "$rid"
        printf '%s\\n' '#{turn_started_frame()}'
        printf '%s\\n' '#{rate_limits_frame(28)}'
        ;;
      *'"method":"account/rateLimits/read"'*)
        case "$line" in
          *'"id":6'*) printf '%s\\n' '#{probe_refusal_frame()}' ;;
        esac
        ;;
    esac
    done
    """
  end

  defp handshake_cases(trace) do
    """
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "#{trace}"
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"#{@thread}"}}}' ;;
    """
  end

  defp turn_started_frame do
    encode_frame(%{
      "method" => "turn/started",
      "params" => %{"threadId" => @thread, "turn" => %{"id" => "turn-1", "status" => "inProgress", "items" => []}}
    })
  end

  defp rate_limits_frame(used_percent) do
    encode_frame(%{
      "method" => "account/rateLimits/updated",
      "params" => %{
        "rateLimits" => %{
          "primary" => %{"usedPercent" => used_percent, "windowDurationMins" => 10_080, "resetsAt" => @resets_at_epoch}
        }
      }
    })
  end

  defp probe_answer_frame(used_percent) do
    encode_frame(%{
      "id" => 6,
      "result" => %{
        "rateLimits" => %{
          "primary" => %{"usedPercent" => used_percent, "windowDurationMins" => 10_080, "resetsAt" => @resets_at_epoch}
        }
      }
    })
  end

  defp probe_refusal_frame do
    encode_frame(%{"id" => 6, "error" => %{"message" => @banner, "codexErrorInfo" => "usageLimitExceeded"}})
  end

  defp delta_frame do
    encode_frame(%{
      "method" => "item/agentMessage/delta",
      "params" => %{"threadId" => @thread, "turnId" => "turn-1", "itemId" => "m1", "delta" => "still working"}
    })
  end

  defp completed_frame do
    encode_frame(%{
      "method" => "turn/completed",
      "params" => %{"threadId" => @thread, "turn" => %{"id" => "turn-1", "status" => "completed", "items" => []}}
    })
  end

  # The frames are printed from a single-quoted printf argument, so an
  # apostrophe in the provider's text has to survive as an escape.
  defp encode_frame(map), do: map |> Jason.encode!() |> String.replace("'", "\\u0027")
end

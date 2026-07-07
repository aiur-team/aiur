defmodule Aiur.Codex.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.CodingAgent

  @pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()

  describe "stop_session/1 reaps the app-server process tree" do
    @tag skip: @pgrep_skip_reason
    # The codex backend launches `bash -lc "codex ... app-server"`. bash forks
    # a `node` -> rust `codex` grandchild it does NOT exec into. Closing only
    # the port kills the bash wrapper and leaves that grandchild reparented to
    # init — a live app-server still holding the global ~/.codex/state_5.sqlite
    # lock, which poisons every subsequent codex agent with "database is locked".
    # Teardown must reap the whole tree.
    test "kills the bash wrapper AND its surviving child" do
      command = "sleep 600 & printf 'up\\n'; wait"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", String.to_charlist(command)], line: 64_000]
        )

      {:os_pid, bash_pid} = :erlang.port_info(port, :os_pid)
      assert_receive {^port, {:data, {:eol, "up"}}}, 2_000

      child_pid = wait_for_child(bash_pid, 2_000)

      on_exit(fn ->
        for p <- [bash_pid, child_pid], is_integer(p) do
          System.cmd("kill", ["-KILL", Integer.to_string(p)], stderr_to_stdout: true)
        end
      end)

      assert is_integer(child_pid)
      assert os_alive?(child_pid)

      assert :ok = CodingAgent.stop_session(%{port: port})

      refute os_alive?(bash_pid)
      refute os_alive?(child_pid)
    end
  end

  describe "thread-init frame (start vs resume)" do
    @policies %{approval_policy: "never", thread_sandbox: "read-only"}

    test "builds a thread/start frame with dynamicTools when not resuming" do
      frame = CodingAgent.thread_init_frame_for_test(nil, "/ws", @policies)

      assert frame["method"] == "thread/start"
      assert frame["id"] == 2
      assert frame["params"]["cwd"] == "/ws"
      assert frame["params"]["approvalPolicy"] == "never"
      assert frame["params"]["sandbox"] == "read-only"
      # A fresh thread registers aiur's custom dynamic tools.
      assert is_list(frame["params"]["dynamicTools"])
    end

    test "builds a thread/resume frame carrying the threadId when resuming" do
      frame = CodingAgent.thread_init_frame_for_test("thr_123", "/ws", @policies)

      assert frame["method"] == "thread/resume"
      assert frame["id"] == 2
      assert frame["params"]["threadId"] == "thr_123"
      assert frame["params"]["cwd"] == "/ws"
      assert frame["params"]["approvalPolicy"] == "never"
      assert frame["params"]["sandbox"] == "read-only"
      # The codex app-server's thread/resume has no dynamicTools param; the
      # registration is restored from the persisted rollout, so we must not
      # send one (it would be rejected as an unknown field).
      refute Map.has_key?(frame["params"], "dynamicTools")
    end
  end

  describe "resume_outcome/2 (resumed vs fresh vs clean-start fallback)" do
    test "a returned thread_id matching the requested one is a genuine resume" do
      assert CodingAgent.resume_outcome({:ok, "thr_1"}, "thr_1") == {:resumed, "thr_1"}
    end

    test "a DIFFERENT returned thread_id is treated as fresh, not a resume" do
      # Guards against codex silently substituting a new/empty thread: reporting
      # resumed?=true there would hand the agent a context-free continuation
      # prompt against a thread it never actually rejoined.
      assert CodingAgent.resume_outcome({:ok, "thr_other"}, "thr_1") == {:fresh, "thr_other"}
    end

    test "a resume error degrades to a clean-start fallback carrying the reason" do
      assert CodingAgent.resume_outcome({:error, {:response_error, %{}}}, "thr_1") ==
               {:fallback, {:response_error, %{}}}

      assert CodingAgent.resume_outcome({:error, :response_timeout}, "thr_1") ==
               {:fallback, :response_timeout}
    end
  end

  describe "parse_thread_response/1" do
    test "extracts the thread id from a well-formed start/resume response" do
      assert CodingAgent.parse_thread_response_for_test({:ok, %{"thread" => %{"id" => "thr_x"}}}) ==
               {:ok, "thr_x"}
    end

    test "a thread payload without an id is an invalid-thread-payload error" do
      assert {:error, {:invalid_thread_payload, %{"name" => "x"}}} =
               CodingAgent.parse_thread_response_for_test({:ok, %{"thread" => %{"name" => "x"}}})
    end

    test "an underlying error response passes through unchanged" do
      assert CodingAgent.parse_thread_response_for_test({:error, :response_timeout}) ==
               {:error, :response_timeout}
    end
  end

  describe "startup response timeout" do
    test "uses a cold-start floor without shortening explicit longer read timeouts" do
      assert CodingAgent.startup_response_timeout_ms_for_test(5_000) == 30_000
      assert CodingAgent.startup_response_timeout_ms_for_test(60_000) == 60_000
    end

    test "waits past the steady read timeout for startup responses" do
      command = "sleep 0.1; printf '%s\\n' '{\"id\":42,\"result\":{\"ok\":true}}'"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", String.to_charlist(command)], line: 64_000]
        )

      assert {:ok, %{"ok" => true}} = CodingAgent.await_startup_response_for_test(port, 42, 50)
      assert_receive {^port, {:exit_status, 0}}, 1_000
    end
  end

  describe "send_thread_init/2 graceful degradation" do
    test "a closed app-server port yields {:error, :port_closed} instead of raising" do
      # A dead app-server makes Port.command raise ArgumentError; the resume path
      # must see an error tuple so it can fall back to a clean start rather than
      # crashing the dispatch (issue #378: degrade gracefully).
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("cat"))},
          [:binary, :exit_status]
        )

      true = Port.close(port)

      frame =
        CodingAgent.thread_init_frame_for_test("thr_1", "/ws", %{
          approval_policy: "never",
          thread_sandbox: "read-only"
        })

      assert {:error, :port_closed} = CodingAgent.send_thread_init_for_test(port, frame)
    end
  end

  defp wait_for_child(parent, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_wait_for_child(parent, deadline)
  end

  defp do_wait_for_child(parent, deadline) do
    first_child =
      case System.cmd("pgrep", ["-P", Integer.to_string(parent)], stderr_to_stdout: true) do
        {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1) |> List.first()
        _ -> nil
      end

    cond do
      is_integer(first_child) ->
        first_child

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(25)
        do_wait_for_child(parent, deadline)
    end
  end

  defp os_alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
end

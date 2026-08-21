defmodule Aiur.PaneManager.ControlUrlPublisherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.PaneManager.ControlUrlPublisher

  test "retries a late dashboard bind and publishes its URL" do
    test_pid = self()
    url_state = start_supervised!({Agent, fn -> nil end})

    publisher =
      start_supervised!(
        {ControlUrlPublisher,
         url_fun: fn -> Agent.get(url_state, & &1) end,
         publish_fun: fn _tmux, url ->
           send(test_pid, {:published, url})
           :ok
         end,
         unpublish_fun: fn _tmux -> :ok end,
         interval_ms: 10}
      )

    refute_receive {:published, _}
    Agent.update(url_state, fn _ -> "http://127.0.0.1:4100" end)

    assert_receive {:published, "http://127.0.0.1:4100"}, 200
    assert Process.alive?(publisher)
  end

  test "reasserts a stable URL and republishes after the listener URL changes" do
    test_pid = self()
    url_state = start_supervised!({Agent, fn -> "http://127.0.0.1:4100" end})

    start_supervised!(
      {ControlUrlPublisher,
       url_fun: fn -> Agent.get(url_state, & &1) end,
       publish_fun: fn _tmux, url ->
         send(test_pid, {:published, url})
         :ok
       end,
       interval_ms: 10}
    )

    assert_receive {:published, "http://127.0.0.1:4100"}, 200
    assert_receive {:published, "http://127.0.0.1:4100"}, 200

    Agent.update(url_state, fn _ -> "http://127.0.0.1:4200" end)
    assert_receive {:published, "http://127.0.0.1:4200"}, 200
  end

  test "clears a retained tmux URL when the dashboard starts unbound" do
    test_pid = self()

    start_supervised!(
      {ControlUrlPublisher,
       url_fun: fn -> nil end,
       unpublish_fun: fn _tmux ->
         send(test_pid, :unpublished)
         :ok
       end,
       interval_ms: 10}
    )

    assert_receive :unpublished, 200
    refute_receive :unpublished, 40
  end

  test "retries publication failures for the same URL" do
    test_pid = self()
    attempts = start_supervised!({Agent, fn -> 0 end})

    log =
      capture_log(fn ->
        start_supervised!(
          {ControlUrlPublisher,
           url_fun: fn -> "http://127.0.0.1:4100" end,
           publish_fun: fn _tmux, url ->
             attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
             send(test_pid, {:attempt, attempt, url})
             if attempt == 1, do: {:error, :tmux_unavailable}, else: :ok
           end,
           interval_ms: 10}
        )

        assert_receive {:attempt, 1, "http://127.0.0.1:4100"}, 200
        assert_receive {:attempt, 2, "http://127.0.0.1:4100"}, 200
      end)

    assert log =~ "action=publish"
    assert log =~ "outcome=failed"
    assert log =~ "reason=:tmux_unavailable"
    assert log =~ "retrying=true"
  end

  test "retries a failed rebind at the retry interval after a prior publication" do
    test_pid = self()
    url_state = start_supervised!({Agent, fn -> "http://127.0.0.1:4100" end})

    rebind_attempts =
      start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :rebind_attempts))

    start_supervised!(
      {ControlUrlPublisher,
       url_fun: fn -> Agent.get(url_state, & &1) end,
       publish_fun: fn _tmux, url ->
         if url == "http://127.0.0.1:4200" do
           attempt = Agent.get_and_update(rebind_attempts, fn count -> {count + 1, count + 1} end)
           send(test_pid, {:rebind_attempt, attempt})
           if attempt == 1, do: {:error, :tmux_unavailable}, else: :ok
         else
           send(test_pid, {:published, url})
           :ok
         end
       end,
       interval_ms: 10,
       stable_interval_ms: 200}
    )

    assert_receive {:published, "http://127.0.0.1:4100"}, 200
    Agent.update(url_state, fn _ -> "http://127.0.0.1:4200" end)

    assert_receive {:rebind_attempt, 1}, 300
    assert_receive {:rebind_attempt, 2}, 100
  end

  test "retries a failed unpublish at the retry interval after a prior publication" do
    test_pid = self()
    url_state = start_supervised!({Agent, fn -> "http://127.0.0.1:4100" end})

    unpublish_attempts =
      start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :unpublish_attempts))

    start_supervised!(
      {ControlUrlPublisher,
       url_fun: fn -> Agent.get(url_state, & &1) end,
       publish_fun: fn _tmux, url ->
         send(test_pid, {:published, url})
         :ok
       end,
       unpublish_fun: fn _tmux ->
         attempt = Agent.get_and_update(unpublish_attempts, fn count -> {count + 1, count + 1} end)
         send(test_pid, {:unpublish_attempt, attempt})
         if attempt == 1, do: {:error, :tmux_unavailable}, else: :ok
       end,
       interval_ms: 10,
       stable_interval_ms: 200}
    )

    assert_receive {:published, "http://127.0.0.1:4100"}, 200
    Agent.update(url_state, fn _ -> nil end)

    assert_receive {:unpublish_attempt, 1}, 300
    assert_receive {:unpublish_attempt, 2}, 100
  end

  test "clears a stale URL while the listener is unbound and publishes the rebound URL" do
    test_pid = self()
    url_state = start_supervised!({Agent, fn -> "http://127.0.0.1:4100" end})

    start_supervised!(
      {ControlUrlPublisher,
       url_fun: fn -> Agent.get(url_state, & &1) end,
       publish_fun: fn _tmux, url ->
         send(test_pid, {:published, url})
         :ok
       end,
       unpublish_fun: fn _tmux ->
         send(test_pid, :unpublished)
         :ok
       end,
       interval_ms: 10}
    )

    assert_receive {:published, "http://127.0.0.1:4100"}, 200
    Agent.update(url_state, fn _ -> nil end)
    assert_receive :unpublished, 200
    refute_receive :unpublished, 40

    Agent.update(url_state, fn _ -> "http://127.0.0.1:4200" end)
    assert_receive {:published, "http://127.0.0.1:4200"}, 200
  end
end

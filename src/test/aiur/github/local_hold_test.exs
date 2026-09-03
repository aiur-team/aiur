defmodule Aiur.GitHub.LocalHoldTest do
  @moduledoc """
  #2444: a short, self-clearing local budget hold is waited out (bounded,
  capped) instead of failing the operation that hit it. This tests the shared
  helper itself; each call site (auth preflight, dispatch revalidation, rework
  re-queue) has its own operation-succeeds test wiring the helper in.
  """

  use ExUnit.Case, async: true

  alias Aiur.GitHub.LocalHold

  defp hold(reset_at), do: %{reason: :shared_budget, resource: "core", reset_at: reset_at}

  defp detail(reset_at) do
    %{reason: {:aiur, :locally_held, hold(reset_at)}, hold: hold(reset_at)}
  end

  # The raw classified error shape `Errors.classify_error/1` produces.
  defp classified_error(reset_at), do: {:error, {:github, :local_hold, detail(reset_at)}}

  describe "run/2 — wait out a short self-clearing local hold (#2444)" do
    test "waits until reset_at then retries; a later attempt succeeds" do
      parent = self()
      reset_at = DateTime.add(DateTime.utc_now(), 2, :second)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        LocalHold.run(
          fn ->
            attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
            if attempt == 1, do: classified_error(reset_at), else: {:ok, :admitted}
          end,
          sleep_fun: fn ms ->
            send(parent, {:sleep, ms})
            :ok
          end
        )

      assert result == {:ok, :admitted}
      # One held attempt, then a successful retry.
      assert Agent.get(counter, & &1) == 2

      # The hold was 2s out, so the wait honours `reset_at` plus up to 500ms of
      # jitter — nothing more.
      assert_receive {:sleep, wait_ms}
      assert wait_ms >= 1_500 and wait_ms <= 2_500
      refute_receive {:sleep, _}
    end

    test "a hold beyond the ceiling fails immediately with no wait (mutation guard)" do
      reset_at = DateTime.add(DateTime.utc_now(), 120, :second)
      error = classified_error(reset_at)

      # The request fun must not even be re-invoked: no wait, no retry — real
      # starvation is not masked by waiting.
      assert error ==
               LocalHold.run(
                 fn -> error end,
                 sleep_fun: fn _ -> flunk("must not sleep for a beyond-ceiling hold") end
               )
    end

    test "a re-armed hold terminates after the configured cap rather than waiting forever" do
      reset_at = DateTime.add(DateTime.utc_now(), 1, :second)
      error = classified_error(reset_at)
      {:ok, sleeps} = Agent.start_link(fn -> 0 end)

      assert error ==
               LocalHold.run(
                 fn -> error end,
                 sleep_fun: fn _ -> Agent.update(sleeps, &(&1 + 1)) end
               )

      # Exactly `max_waits` waits, then the next attempt fails closed.
      assert Agent.get(sleeps, & &1) == LocalHold.max_waits()
    end

    test "a reset_at already passed is retried immediately and succeeds" do
      reset_at = DateTime.add(DateTime.utc_now(), -1, :second)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      {:ok, sleeps} = Agent.start_link(fn -> 0 end)

      result =
        LocalHold.run(
          fn ->
            attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
            if attempt == 1, do: classified_error(reset_at), else: {:ok, :admitted}
          end,
          sleep_fun: fn _ -> Agent.update(sleeps, &(&1 + 1)) end
        )

      assert result == {:ok, :admitted}
      assert Agent.get(counter, & &1) == 2
      # Nothing to wait for — `reset_at` already passed.
      assert Agent.get(sleeps, & &1) == 0
    end

    test "non-local-hold results pass through unchanged" do
      assert {:ok, :fine} == LocalHold.run(fn -> {:ok, :fine} end)
      assert :ok == LocalHold.run(fn -> :ok end)
      assert {:error, :boom} == LocalHold.run(fn -> {:error, :boom} end)

      assert {:error, {:github, :timeout, %{reason: :timeout}}} ==
               LocalHold.run(fn -> {:error, {:github, :timeout, %{reason: :timeout}}} end)
    end

    test "the auth-preflight diagnostic shape is retried the same way" do
      parent = self()
      reset_at = DateTime.add(DateTime.utc_now(), 1, :second)

      diagnostic_error =
        {:error,
         %{
           classification: :local_hold,
           detail: detail(reset_at),
           endpoint: :repository,
           repo: "owner/repo",
           token_source: "GITHUB_APP"
         }}

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        LocalHold.run(
          fn ->
            attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
            if attempt == 1, do: diagnostic_error, else: :ok
          end,
          sleep_fun: fn ms ->
            send(parent, {:sleep, ms})
            :ok
          end
        )

      assert result == :ok
      assert Agent.get(counter, & &1) == 2
      assert_receive {:sleep, _}
    end
  end

  describe "run/2 — budget broker timeout wait-out (#2457)" do
    # The raw classified error `Errors.classify_error/1` produces for a
    # broker timeout.
    defp broker_timeout_error, do: {:error, {:github, :timeout, %{reason: :github_budget_broker_timeout}}}

    # #2457 acceptance 1: a broker timeout (transient per the shared
    # classifier, no `reset_at` to aim at) is backed off and retried, so the
    # operation survives instead of failing the run. The assertion is on the
    # retry succeeding and the backoff actually happening, not on a log line.
    test "a budget broker timeout is backed off and the retry succeeds" do
      parent = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        LocalHold.run(
          fn ->
            attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
            if attempt == 1, do: broker_timeout_error(), else: {:ok, :admitted}
          end,
          sleep_fun: fn ms ->
            send(parent, {:sleep, ms})
            :ok
          end
        )

      assert result == {:ok, :admitted}
      # One timed-out attempt, then a successful retry.
      assert Agent.get(counter, & &1) == 2

      # First backoff is `backoff_base_ms` plus up to `jitter_ms` — nothing
      # more.
      assert_receive {:sleep, wait_ms}
      assert wait_ms >= LocalHold.backoff_base_ms()
      assert wait_ms <= LocalHold.backoff_base_ms() + LocalHold.jitter_ms()
      refute_receive {:sleep, _}
    end

    test "the broker-timeout backoff grows exponentially across consecutive retries" do
      parent = self()

      LocalHold.run(
        fn -> broker_timeout_error() end,
        sleep_fun: fn ms ->
          send(parent, {:sleep, ms})
          :ok
        end
      )

      base = LocalHold.backoff_base_ms()
      jitter = LocalHold.jitter_ms()

      assert_receive {:sleep, first}
      assert first >= base and first <= base + jitter

      assert_receive {:sleep, second}
      assert second >= 2 * base and second <= 2 * base + jitter

      assert_receive {:sleep, third}
      assert third >= 4 * base and third <= 4 * base + jitter

      refute_receive {:sleep, _}
    end

    # #2457 acceptance 3: consecutive retries are capped, so a persistently
    # unreachable broker fails closed rather than pinning the workspace.
    test "a persistently unreachable broker terminates after the configured cap" do
      error = broker_timeout_error()
      {:ok, sleeps} = Agent.start_link(fn -> 0 end)
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      assert error ==
               LocalHold.run(
                 fn ->
                   Agent.update(attempts, &(&1 + 1))
                   error
                 end,
                 sleep_fun: fn _ -> Agent.update(sleeps, &(&1 + 1)) end
               )

      # Exactly `max_waits` waits, then the next attempt fails closed.
      assert Agent.get(sleeps, & &1) == LocalHold.max_waits()
      assert Agent.get(attempts, & &1) == LocalHold.max_waits() + 1
    end

    # #2457 acceptance 2: a malformed broker reply (broker unavailable) is
    # permanent per the shared classifier and must NOT be retried — this is
    # the guard that keeps the fix from becoming blanket retry.
    test "a permanent broker-unavailable failure passes through unchanged" do
      error = {:error, {:github, :transport, %{reason: :github_budget_broker_unavailable}}}

      # The attempt fun must not even be re-invoked: no wait, no retry.
      assert error ==
               LocalHold.run(
                 fn -> error end,
                 sleep_fun: fn _ -> flunk("must not sleep for a permanent broker fault") end
               )
    end

    test "the auth-preflight diagnostic broker-timeout shape is backed off the same way" do
      parent = self()

      diagnostic_error =
        {:error,
         %{
           classification: :timeout,
           detail: %{reason: :github_budget_broker_timeout},
           endpoint: :issues,
           repo: "owner/repo",
           token_source: "GITHUB_APP"
         }}

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        LocalHold.run(
          fn ->
            attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
            if attempt == 1, do: diagnostic_error, else: :ok
          end,
          sleep_fun: fn ms ->
            send(parent, {:sleep, ms})
            :ok
          end
        )

      assert result == :ok
      assert Agent.get(counter, & &1) == 2
      assert_receive {:sleep, _}
    end

    # #2464: every broker-timeout backoff feeds the retry-rate signal; the
    # individual retry is uninteresting but it is the raw count a future
    # investigation queries. The recorder is injectable so the assertion is on
    # the retry path calling it, not on the running monitor.
    test "each broker-timeout backoff records the retry-rate signal" do
      {:ok, records} = Agent.start_link(fn -> 0 end)

      recorder = fn -> Agent.update(records, &(&1 + 1)) end

      # Always times out: the operation fails closed after the cap, and every
      # wait along the way is a broker-timeout backoff that must record.
      assert {:error, {:github, :timeout, %{reason: :github_budget_broker_timeout}}} =
               LocalHold.run(
                 fn -> broker_timeout_error() end,
                 sleep_fun: fn _ -> :ok end,
                 broker_timeout_recorder: recorder
               )

      # One record per wait, i.e. `max_waits` total — the fail-closed final
      # attempt is not a retry and records nothing.
      assert Agent.get(records, & &1) == LocalHold.max_waits()
    end

    # #2464: the retry-rate signal is specific to the broker timeout. A local
    # hold is a different fault with its own visibility; counting it as a
    # broker-timeout retry would inflate the rate with a benign condition.
    test "a local hold backoff does not record the broker-timeout signal" do
      reset_at = DateTime.add(DateTime.utc_now(), 1, :second)
      error = classified_error(reset_at)

      LocalHold.run(
        fn -> error end,
        sleep_fun: fn _ -> :ok end,
        broker_timeout_recorder: fn -> flunk("a local hold must not record the broker-timeout signal") end
      )

      assert true
    end
  end
end

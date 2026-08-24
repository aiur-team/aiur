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
end

defmodule Aiur.PubSub.Boot do
  @moduledoc """
  Starts `Phoenix.PubSub` for `Aiur.PubSub` only once the names of a previous
  incarnation have been released.

  `Aiur.PubSub` is a partitioned `Registry`: the name `Aiur.PubSub` belongs to
  the registry's own supervisor, and each partition owns a registered name of
  its own (`Aiur.PubSub.PIDPartition0`, `Aiur.PubSub.KeyPartition0`, …). When
  that supervisor dies, its partitions die too — but *asynchronously*, over the
  links, at whatever moment the scheduler next runs them.

  A supervisor's restart is synchronous and immediate, and OTP retries a failed
  start with no backoff at all. So the restart consistently loses the race with
  the dying partitions (#2557):

      Aiur.PubSub          start_error  {:already_started, #PID<0.470.0>}
                                        offender: Aiur.PubSub.PIDPartition0
      Aiur.PubSub.Supervisor start_error {:shutdown, {:failed_to_start_child,
                                          Aiur.PubSub.PIDPartition0, …}}
      … x3 within 600us …
      Aiur.PubSub.Supervisor shutdown   :reached_max_restart_intensity

  `Phoenix.PubSub.Supervisor` is `Aiur.Supervisor`'s first child, so its death
  is then handled by `:rest_for_one` exactly as #2525 intended — except that
  `Aiur.Supervisor`'s own restart hits the *same* still-registered partition,
  fails three times just as fast, and the whole ~90-child tree exits
  `:shutdown` with it. Whether that happens is decided purely by whether one
  `Registry.Partition` process gets scheduled inside a few hundred
  microseconds, which is why the same suite passed for months and then began
  failing when partition membership shifted the load around it.

  Waiting for the stale names is the fix: it costs nothing on a cold boot
  (there is nothing to wait for) and turns the restart from a scheduling race
  into an ordinary, deterministic start. The wait is bounded and fails open —
  a genuinely stuck name still gets the old behaviour, loudly, rather than
  hanging boot.
  """

  require Logger

  @name Aiur.PubSub
  # Generous: the observed window is single-digit milliseconds, and the only
  # cost of a high ceiling is how long a genuinely wedged name delays boot.
  @await_ms 5_000
  @poll_ms 2

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    # Deliberately the id `Phoenix.PubSub` would have produced. `Aiur.PubSub`'s
    # child id is part of the application's contract: `Aiur.TestSupport` and
    # `Aiur.SupervisionHealth` both address this child by it.
    %{
      id: Phoenix.PubSub.Supervisor,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      shutdown: :infinity
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    await_names_released(System.monotonic_time(:millisecond) + @await_ms)
    Phoenix.PubSub.Supervisor.start_link(opts)
  end

  defp await_names_released(deadline) do
    case held_names() do
      [] ->
        :ok

      names ->
        if System.monotonic_time(:millisecond) >= deadline do
          Logger.warning("aiur_pubsub_boot stale_names=#{inspect(names)} waited_ms=#{@await_ms} action=starting_anyway")
          :ok
        else
          Process.sleep(@poll_ms)
          await_names_released(deadline)
        end
    end
  end

  # Every name the registry and its partitions register, without depending on
  # the partition count (`Phoenix.PubSub` derives it from `schedulers_online`).
  defp held_names do
    prefix = Atom.to_string(@name) <> "."

    Enum.filter(Process.registered(), fn name ->
      name == @name or String.starts_with?(Atom.to_string(name), prefix)
    end)
  end
end

defmodule Aiur.BootTest do
  use ExUnit.Case, async: false

  alias Aiur.Boot

  @start_key {Boot, :start_ms}
  @epoch_key {Boot, :start_epoch_seconds}
  @started_at_key {Boot, :started_at}
  @run_id_key {Boot, :run_id}

  setup do
    original_start = :persistent_term.get(@start_key, :unset)
    original_epoch = :persistent_term.get(@epoch_key, :unset)
    original_started_at = :persistent_term.get(@started_at_key, :unset)
    original_run_id = :persistent_term.get(@run_id_key, :unset)

    on_exit(fn ->
      restore(@start_key, original_start)
      restore(@epoch_key, original_epoch)
      restore(@started_at_key, original_started_at)
      restore(@run_id_key, original_run_id)
    end)

    :ok
  end

  defp restore(key, :unset), do: :persistent_term.erase(key)
  defp restore(key, value), do: :persistent_term.put(key, value)

  test "mark/0 mints start time, epoch, and run_id together, then is a no-op" do
    :persistent_term.erase(@start_key)
    :persistent_term.erase(@epoch_key)
    :persistent_term.erase(@run_id_key)

    assert :ok = Boot.mark()
    run_id = Boot.run_id()
    epoch = Boot.epoch_seconds()
    assert is_binary(run_id)
    assert is_integer(epoch)

    # Re-marking must not mint a new run_id or reset the clock.
    assert :ok = Boot.mark()
    assert Boot.run_id() == run_id
    assert Boot.epoch_seconds() == epoch
  end

  test "remark/0 mints a new run_id together with the clock reset" do
    Boot.mark()
    original_run_id = Boot.run_id()

    assert :ok = Boot.remark()

    refute Boot.run_id() == original_run_id
    assert is_integer(Boot.epoch_seconds())
  end

  test "run_id/0 lazily mints and caches one stable value when mark/0 hasn't run" do
    :persistent_term.erase(@run_id_key)

    id = Boot.run_id()
    assert is_binary(id)
    assert Boot.run_id() == id
  end

  test "started_at/0 is sub-second precision and consistent with epoch_seconds/0" do
    :persistent_term.erase(@start_key)
    :persistent_term.erase(@epoch_key)
    :persistent_term.erase(@started_at_key)

    Boot.mark()

    assert %DateTime{microsecond: {_value, precision}} = Boot.started_at()
    assert precision > 0
    assert DateTime.to_unix(Boot.started_at(), :second) == Boot.epoch_seconds()
  end

  test "remark/0 advances started_at/0 together with the other clocks" do
    Boot.mark()
    original_started_at = Boot.started_at()

    assert :ok = Boot.remark()

    assert DateTime.compare(Boot.started_at(), original_started_at) != :lt
  end
end

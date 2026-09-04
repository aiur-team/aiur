defmodule Aiur.Webhooks.ModeTableTest do
  @moduledoc """
  The ETS view `ReadCache.Policy` reads the delivery transport from.

  The read-cache TTL decision runs on every cacheable GitHub request, so it
  reads this table rather than taking a `ModeRegistry` round trip. These tests
  pin the table's own contract: an unrecorded repo reads back as `:polling`
  (the conservative short-TTL answer), a recorded mode is served back, and the
  key normalizes the same way `ModeRegistry` normalizes its repo keys so a
  delivery-cased publish and a config-cased read resolve to one entry.
  """

  use ExUnit.Case, async: false

  alias Aiur.Webhooks.{DeliveryMode, ModeTable}

  # Deliberately not the live `aiur-team/aiur`. `ModeTable` is a process-global
  # ETS keyed by repo string, and ten test modules write it; any of them that
  # records the live repo and lands in this partition makes the unrecorded-repo
  # case below read back `:webhook`. Keys unique to this module cannot collide,
  # whichever partition each module is packed into (#2548).
  @repo "aiur-team/mode-table-test-repo"
  @key_repo "aiur-team/mode-table-key-test-repo"

  setup do
    on_exit(fn -> ModeTable.delete(@repo) && ModeTable.delete(@key_repo) end)
    :ok
  end

  test "an unrecorded repo reads back as polling, the conservative default" do
    assert ModeTable.transport(@repo) == :polling
  end

  test "a recorded webhook-backed mode is served back to the reader" do
    ModeTable.put(@repo, webhook_backed())
    assert ModeTable.transport(@repo) == :webhook
  end

  test "a degraded mode reads back as polling" do
    ModeTable.put(@repo, degraded())
    assert ModeTable.transport(@repo) == :polling
  end

  test "delete removes a recorded mode" do
    ModeTable.put(@repo, webhook_backed())
    assert ModeTable.transport(@repo) == :webhook

    ModeTable.delete(@repo)

    assert ModeTable.transport(@repo) == :polling
  end

  test "repo names normalize case-insensitively, matching the registry" do
    # `ModeRegistry` normalizes its keys, so a delivery-cased publish and a
    # config-cased read must land on the same entry or the TTL would see two
    # different repos.
    ModeTable.put("AIUR-Team/Mode-Table-Test-Repo", webhook_backed())
    assert ModeTable.transport(@repo) == :webhook
    assert ModeTable.transport("Aiur-Team/MODE-TABLE-TEST-REPO") == :webhook
  end

  defp webhook_backed do
    {mode, :proven} = DeliveryMode.new(@repo, configured?: true) |> DeliveryMode.record_delivery(~U[2026-01-01 00:00:00Z])
    mode
  end

  defp degraded do
    {proven, _} = DeliveryMode.new(@repo, configured?: true) |> DeliveryMode.record_delivery(~U[2026-01-01 00:00:00Z])
    {active, _} = DeliveryMode.record_activity(proven, ~U[2026-01-01 00:16:00Z])
    {degraded, :degraded} = DeliveryMode.sweep(active, ~U[2026-01-01 00:16:00Z], 900_000)
    degraded
  end
end

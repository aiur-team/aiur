defmodule Aiur.CurrentRunMembershipStoreSupport do
  @moduledoc false

  import ExUnit.Assertions

  alias Aiur.CurrentRunMembership.Store
  alias Aiur.TrackerIdentity

  @run_id "membership-store-test"
  @now ~U[2026-07-14 12:00:00Z]
  @async_assert_timeout 2_000

  def start_store!(dir, run_id \\ @run_id, opts \\ []) do
    defaults = [name: nil, state_dir: dir, run_id: run_id, checkpoint_interval: 1]
    {:ok, pid} = Store.start_link(Keyword.merge(defaults, opts))
    pid
  end

  def observe(pid, identity, lifecycle, seconds \\ 0) do
    Store.observe(identity, lifecycle, server: pid, observed_at: DateTime.add(@now, seconds, :second))
  end

  def identity(owner \\ "owner", repository \\ "repo", provider_id \\ "I-42", identifier \\ "42") do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: repository,
      provider_id: provider_id,
      identifier: identifier,
      reason: nil
    }
  end

  def checkpoint_path(dir), do: only_path(dir, "membership.checkpoint.json")
  def journal_path(dir), do: only_path(dir, "membership.ndjson")

  def checkpoint_checksum(record) do
    {record["version"], record["run_id"], record["generation"], record["members"]}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def only_path(dir, filename) do
    [path] = Path.wildcard(Path.join([dir, "runs", "*", filename]))
    path
  end

  def stop(pid), do: Aiur.TestSupport.safe_stop(pid)

  def crash(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, @async_assert_timeout
  end
end

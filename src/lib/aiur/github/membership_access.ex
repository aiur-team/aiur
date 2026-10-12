defmodule Aiur.GitHub.MembershipAccess do
  @moduledoc """
  Serializes membership access through the resource store owner.

  An owner timeout or exit exits `{:membership_unavailable, reason}`; a timeout
  carries `{:aiur, :unknown, :timeout}` (see `Aiur.GitHub.Errors.outcome/1`). The
  queued call may still run later, so callers must reconcile rather than assume
  it did not happen.
  """

  @table Aiur.GitHub.ResourceStore.Table

  # Only membership needs set-level serialization. Other resource types keep
  # their existing direct ETS/CAS path. Reentrant calls on the owner run inline.
  @spec run(term(), term(), (-> term())) :: term()
  def run({:sub_issue, _, _, _}, default, fun), do: run(:sub_issue, default, fun)

  def run(:sub_issue, default, fun) do
    case :ets.info(@table, :owner) do
      :undefined -> default
      owner when owner == self() -> fun.()
      owner -> GenServer.call(owner, {:membership_access, fun}, 15_000)
    end
  catch
    # A queued call may still execute after a timeout. Neither timeout nor
    # owner death proves a write completed (or that a read found no members).
    # Keep the failure distinct so webhook delivery cannot confirm old data.
    :exit, {:timeout, _call} -> exit({:membership_unavailable, {:aiur, :unknown, :timeout}})
    :exit, reason -> exit({:membership_unavailable, reason})
  end

  def run(_other, _default, fun), do: fun.()
end

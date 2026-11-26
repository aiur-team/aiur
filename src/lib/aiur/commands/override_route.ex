defmodule Aiur.Commands.OverrideRoute do
  @moduledoc "Pure routing of Command overrides from PR, worker and capacity observations."

  @type route :: :active_worker | :resume_pending | :capacity_wait | :corrective_ticket | :replacement

  @spec choose(term(), term(), term()) :: route()
  def choose(:merged, _worker, _capacity), do: :corrective_ticket
  def choose(%{merged?: true}, _worker, _capacity), do: :corrective_ticket
  def choose(_pr, :active, _capacity), do: :active_worker
  def choose(_pr, :unrecoverable, _capacity), do: :replacement
  def choose(_pr, _worker, :full), do: :capacity_wait
  def choose(_pr, _worker, _capacity), do: :resume_pending
end

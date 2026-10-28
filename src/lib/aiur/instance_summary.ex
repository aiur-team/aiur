defmodule Aiur.InstanceSummary do
  @moduledoc """
  Small RPC-only instance summary. Unimplemented fields remain value-free facts.

  `:providers` maps field names (`:active`, `:capacity`, `:globally_paused`,
  `:awaiting`, `:awaiting_blocking`, `:executor`, `:build_orders`,
  `:background_agents`, `:capabilities`) to zero-arity fact providers.
  `:instance_id` accepts a zero-arity identity provider returning a string or nil.
  All providers run concurrently, unlinked, within `:field_budget_ms` (300 ms)
  and `:total_budget_ms` (1,500 ms). `:now` injects the envelope clock.
  """

  alias Aiur.InstanceSummary.{Fact, Guard}

  @fields ~w(active capacity globally_paused awaiting awaiting_blocking executor build_orders background_agents capabilities)a

  @spec v1(keyword()) :: map()
  def v1(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0) |> DateTime.to_iso8601()
    facts = collect(opts)

    %{
      contract: "aiur.instance_summary",
      version: 1,
      instance_id: facts.instance_id,
      observed_at: now,
      agents: Map.take(facts, [:active, :capacity]),
      fleet: Map.take(facts, [:globally_paused]),
      commands: Map.take(facts, [:awaiting, :awaiting_blocking]),
      executor: facts.executor,
      build_orders: facts.build_orders,
      background_agents: facts.background_agents,
      capabilities: facts.capabilities
    }
    |> Guard.check!()
  end

  defp collect(opts) do
    providers = Keyword.get(opts, :providers, %{})
    {:ok, supervisor} = Task.Supervisor.start_link()
    started = System.monotonic_time(:millisecond)
    budget = min(Keyword.get(opts, :field_budget_ms, 300), Keyword.get(opts, :total_budget_ms, 1_500))

    try do
      tasks =
        Enum.map([:instance_id | @fields], fn field ->
          provider = provider(field, providers, opts)
          {field, Task.Supervisor.async_nolink(supervisor, fn -> invoke(provider) end)}
        end)

      Map.new(tasks, fn {field, task} ->
        remaining = max(0, budget - (System.monotonic_time(:millisecond) - started))
        result = Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill)
        {field, result_value(result, field)}
      end)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp provider(:instance_id, _providers, opts), do: Keyword.get(opts, :instance_id, &Aiur.Identity.instance_id/0)
  defp provider(field, providers, _opts), do: Map.get(providers, field, fn -> Fact.unavailable("not_implemented") end)

  defp invoke(provider) do
    {:value, provider.()}
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  defp result_value({:ok, {:value, id}}, :instance_id) when is_binary(id) or is_nil(id), do: id
  defp result_value(_, :instance_id), do: nil
  defp result_value({:ok, {:value, fact}}, _field), do: fact
  defp result_value(_, _field), do: Fact.unknown("provider_failed")
end

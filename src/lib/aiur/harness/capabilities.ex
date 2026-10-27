defmodule Aiur.Harness.Capabilities do
  @moduledoc "Delivery descriptors, capture gates and derived support for optional harness callbacks."

  alias Aiur.CodingAgent.Registry

  @type hosted_security :: %{
          permission_boundary: :codex_sandbox | :claude_permission_mode | :enforced | :unknown,
          network_boundary: :codex_sandbox | :denied | :unrestricted | :unknown,
          credential_boundary: :daemon | :agent | :unknown
        }

  @doc "Return hosted-execution security facts for a registered harness."
  @spec hosted_security(String.t()) :: {:ok, hosted_security()} | {:error, :unknown_backend}
  def hosted_security(backend) do
    case Map.fetch(Registry.entries(), backend) do
      {:ok, entry} -> {:ok, hosted_security_for_entry(entry)}
      :error -> {:error, :unknown_backend}
    end
  end

  @doc "Project declared hosted-execution facts, defaulting every missing boundary to unknown."
  @spec hosted_security_for_entry(map()) :: hosted_security()
  def hosted_security_for_entry(entry) do
    hosted = if is_map(entry[:hosted_execution]), do: entry.hosted_execution, else: %{}

    %{
      permission_boundary: Map.get(hosted, :permission_boundary, :unknown),
      network_boundary: Map.get(hosted, :network_boundary, :unknown),
      credential_boundary: Map.get(hosted, :credential_boundary, :unknown)
    }
  end

  @doc "Return delivery primitives for a registered harness; unknown keys never get a guessed profile."
  @spec delivery_primitives(String.t()) :: {:ok, map()} | {:error, :unknown_backend}
  def delivery_primitives(backend) do
    case Map.fetch(Registry.entries(), backend) do
      {:ok, entry} -> {:ok, delivery_primitives_for_entry(backend, entry)}
      :error -> {:error, :unknown_backend}
    end
  end

  @doc "Derive callback and scheduling facts without branching on harness identity."
  @spec delivery_primitives_for_entry(String.t(), map()) :: map()
  def delivery_primitives_for_entry(key, entry) do
    adapter = entry.adapter
    Code.ensure_loaded!(adapter)
    delivery = Map.get(entry, :delivery, %{})

    %{
      harness_id: key,
      transport: Map.get(delivery, :transport, :unknown),
      turn_boundary_start: function_exported?(adapter, :run_turn, 4),
      mid_turn_inject: Map.get(delivery, :mid_turn_inject, :none),
      hard_interrupt: hard_interrupt(entry),
      native_queue: entry[:immediate_delivery] == true,
      pull_tool: Map.get(delivery, :pull_tool, false),
      hook_boundaries: Map.get(delivery, :hook_boundaries, []),
      native_question: native_question(delivery)
    }
    |> maybe_put_native_question_reason(delivery)
  end

  defp native_question(%{native_question_gate: gate} = delivery) do
    if Aiur.Config.decisions_native_capture?(gate), do: delivery.native_question, else: :none
  end

  defp native_question(delivery), do: Map.get(delivery, :native_question, :none)

  defp maybe_put_native_question_reason(capabilities, %{native_question_gate: _gate}) do
    Map.put(capabilities, :native_question_reason, if(capabilities.native_question == :none, do: :gate_off))
  end

  defp maybe_put_native_question_reason(capabilities, _delivery), do: capabilities

  defp hard_interrupt(entry) do
    cond do
      entry[:can_interrupt] != true -> :none
      function_exported?(entry.adapter, :interrupt, 1) -> :out_of_band
      true -> :in_band
    end
  end

  @type callback_support :: %{
          steer: :native | :none,
          native_question_reply: :native | :none
        }

  @doc "Report implemented optional callbacks for a registered backend."
  @spec callback_support(Aiur.CodingAgent.backend()) :: callback_support() | {:error, :unknown_backend}
  def callback_support(backend) do
    case Map.fetch(Aiur.CodingAgent.backends(), backend) do
      {:ok, entry} -> callback_support_for_module(entry.adapter)
      :error -> {:error, :unknown_backend}
    end
  end

  @doc "Report callback exports after loading the adapter; native questions require reply and release."
  @spec callback_support_for_module(module()) :: callback_support()
  def callback_support_for_module(adapter) do
    {:module, ^adapter} = Code.ensure_loaded(adapter)

    %{
      steer: support(function_exported?(adapter, :steer, 3)),
      native_question_reply:
        support(
          function_exported?(adapter, :reply_native_question, 3) and
            function_exported?(adapter, :release_native_question, 3)
        )
    }
  end

  defp support(true), do: :native
  defp support(false), do: :none
end

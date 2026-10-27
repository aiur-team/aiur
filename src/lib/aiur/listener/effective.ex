defmodule Aiur.Listener.Effective do
  @moduledoc "Pure requested-to-effective listener mode projection from running harness facts."

  @type mode :: :steer | :sync | :async
  @type support :: %{
          status: :proven | :experimental | :blocked_without_wrapper | :unsupported | :unknown,
          carrier: :native | :emulated_interrupt | nil,
          reason: atom() | nil
        }
  @type view :: %{
          requested: mode(),
          effective: mode() | nil,
          effective_reason: atom() | nil,
          version: non_neg_integer(),
          actor: atom(),
          harness_source: :session | :dispatch | nil,
          support: %{steer: support(), sync: support(), async: support()}
        }

  @doc "Derive support and fallback without persisting state or delivering messages."
  @spec compute(map(), nil | map(), keyword()) :: view()
  @spec compute(map(), nil | map()) :: view()
  def compute(mode_record, harness, opts \\ []) do
    {support, unavailable_reason} = derive_support(harness, opts)
    requested = mode_record.requested
    effective = Enum.find([requested, :sync, :async], &usable?(support[&1]))
    reason = unavailable_reason || if(effective != requested, do: support[requested].reason)

    %{
      requested: requested,
      effective: effective,
      effective_reason: reason || pending_reason(harness),
      version: mode_record.version,
      actor: mode_record.actor,
      harness_source: if(harness, do: harness.source),
      support: support
    }
  end

  defp derive_support(nil, _opts), do: unavailable(:not_running)
  defp derive_support(%{primitives: :unknown}, _opts), do: unavailable(:harness_unknown)

  defp derive_support(%{primitives: primitives} = harness, opts) do
    {%{
       sync: sync_support(harness),
       steer: steer_support(harness, opts),
       async: async_support(primitives, opts)
     }, nil}
  end

  defp unavailable(reason) do
    {Map.new([:steer, :sync, :async], &{&1, support(:unknown, nil, reason)}), reason}
  end

  defp sync_support(%{primitives: %{turn_boundary_start: false}}), do: support(:unsupported, nil, :no_turn_boundary)
  defp sync_support(%{harness_id: "claude-repl"}), do: support(:experimental)
  defp sync_support(%{primitives: %{turn_boundary_start: true}}), do: support(:proven)

  defp steer_support(%{callbacks: %{steer: :native}}, _opts), do: support(:experimental, :native)

  defp steer_support(%{primitives: %{hard_interrupt: :none}}, _opts), do: support(:unsupported, nil, :no_interrupt)

  defp steer_support(%{primitives: %{hard_interrupt: interrupt}}, opts) when interrupt in [:in_band, :out_of_band] do
    if Keyword.get(opts, :emulated_interrupt_accepted?, false) do
      support(:experimental, :emulated_interrupt)
    else
      support(:unsupported, nil, :steer_not_wired)
    end
  end

  defp async_support(primitives, opts) do
    if primitives.pull_tool and Keyword.get(opts, :pull_tool_installed?, false) do
      support(:proven)
    else
      support(:unsupported, nil, :pull_tool_unavailable)
    end
  end

  defp usable?(%{status: status}), do: status in [:proven, :experimental]
  defp pending_reason(%{source: :dispatch}), do: :pending_session_start
  defp pending_reason(_harness), do: nil
  defp support(status, carrier \\ nil, reason \\ nil), do: %{status: status, carrier: carrier, reason: reason}
end

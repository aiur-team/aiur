defmodule Aiur.Listener.CapabilityProvider do
  @moduledoc "Read-only listener routing availability for the capability registry."
  @behaviour Aiur.Capabilities.Provider

  alias Aiur.Listener.SpecStatus

  @unknown %{state: :unknown, reason: :unknown}
  # The listener contract explicitly selects the vendored v1 specification.
  @spec_major 1

  @impl true
  def capability_ids, do: ["listener_modes"]

  @impl true
  def capabilities(context), do: capabilities(context, [])

  @doc false
  @spec capabilities(Aiur.Capabilities.Provider.context(), keyword()) :: map()
  def capabilities(_context, opts) do
    status = Keyword.get(opts, :spec_status_fun, &SpecStatus.read/0).()
    flag = Application.get_env(:aiur, :listener_send_routing, :listener)

    entry =
      cond do
        status == {:error, :not_installed} -> %{state: :unavailable, reason: :not_installed}
        status == {:error, :spec_invalid} -> %{state: :unavailable, reason: :spec_invalid}
        status != :ok -> @unknown
        flag != :listener -> %{state: :unavailable, reason: :disabled}
        true -> %{state: :available, version: @spec_major}
      end

    %{"listener_modes" => entry}
  rescue
    _error -> %{"listener_modes" => @unknown}
  catch
    _kind, _reason -> %{"listener_modes" => @unknown}
  end
end

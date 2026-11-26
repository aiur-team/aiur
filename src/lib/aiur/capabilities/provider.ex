defmodule Aiur.Capabilities.Provider do
  @moduledoc "Read-only contributions to the instance capability report. Callbacks must not mutate their sources."

  @type entry :: %{required(:state) => :available | :degraded | :unavailable | :unknown, optional(atom()) => term()}
  @type context :: %{run_shape: map(), settings: map() | :unavailable}

  @callback capability_ids() :: [String.t()]
  @callback capabilities(context()) :: %{String.t() => entry()}
  @callback sections(context()) :: %{optional(:repository | :executor) => map() | nil}
  @optional_callbacks sections: 1

  @doc "Reads the listener directly so provider collection is order-independent."
  @spec http(context(), keyword()) :: entry()
  def http(context, opts \\ []) do
    if context.run_shape.http_listener do
      port = Keyword.get(opts, :http_port_fun, &http_port/0).()
      if is_integer(port) and port > 0, do: %{state: :available}, else: %{state: :unavailable, reason: :not_running}
    else
      %{state: :unavailable, reason: :not_installed}
    end
  end

  @spec writable(context()) :: boolean() | :unknown
  def writable(%{settings: %{observability: %{dashboard_writable: value}}}) when is_boolean(value), do: value
  def writable(_context), do: :unknown

  @spec dependency(String.t(), :unavailable | :degraded) :: entry()
  def dependency(id, state \\ :unavailable), do: %{state: state, reason: :dependency_unavailable, depends_on: [id]}

  @doc "Classifies credential presence without returning its value."
  @spec present?(term()) :: boolean()
  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(_value), do: false

  defp http_port do
    # HttpServer is a startup facade; the listener belongs to this registered endpoint.
    case Bandit.PhoenixAdapter.server_info(:"Elixir.AiurWeb.Endpoint", :http) do
      {:ok, {_address, port}} -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end
end

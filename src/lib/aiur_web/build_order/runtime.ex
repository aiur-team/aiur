defmodule AiurWeb.BuildOrder.Runtime do
  @moduledoc "Failure-aware helpers for Build Order LiveView data boundaries."

  require Logger

  @spec safe_source_call(module() | {module(), term()}, atom(), [term()], term()) :: term()
  def safe_source_call(source, function, args, fallback) do
    source_call(source, function, args)
  rescue
    error ->
      Logger.warning("build_order source call failed operation=#{function} kind=exception exception=#{inspect(error.__struct__)}")

      fallback
  catch
    :exit, reason ->
      Logger.warning("build_order source call failed operation=#{function} kind=exit reason=#{exit_reason(reason)}")

      fallback
  end

  @spec unavailable_sources() :: %{activity: :unavailable, execution: :unavailable}
  def unavailable_sources, do: %{execution: :unavailable, activity: :unavailable}

  @spec display_now() :: DateTime.t()
  def display_now do
    case Application.get_env(:aiur, :build_order_display_clock, &DateTime.utc_now/0).() do
      %DateTime{} = now -> now
      _now -> DateTime.utc_now()
    end
  rescue
    _error -> DateTime.utc_now()
  catch
    _kind, _reason -> DateTime.utc_now()
  end

  @spec tracker_kind() :: String.t()
  def tracker_kind, do: configured_kind(:tracker_kind, &Aiur.Config.tracker_kind/0, "tracker unavailable")

  @spec agent_kind() :: String.t()
  def agent_kind, do: configured_kind(:agent_kind, &Aiur.Config.agent_kind/0, "agent unavailable")

  defp source_call({module, context}, function, args), do: apply(module, function, [context | args])
  defp source_call(module, function, args) when is_atom(module), do: apply(module, function, args)

  defp configured_kind(field, provider, fallback) do
    case provider.() do
      value when is_atom(value) or is_binary(value) ->
        to_string(value)

      _value ->
        Logger.warning("build_order configuration unavailable field=#{field} reason=invalid_value")
        fallback
    end
  rescue
    error ->
      Logger.warning("build_order configuration unavailable field=#{field} reason=exception exception=#{inspect(error.__struct__)}")

      fallback
  catch
    :exit, reason ->
      Logger.warning("build_order configuration unavailable field=#{field} reason=exit exit_reason=#{exit_reason(reason)}")

      fallback
  end

  defp exit_reason({reason, _detail}) when is_atom(reason), do: reason
  defp exit_reason(reason) when is_atom(reason), do: reason
  defp exit_reason(_reason), do: :unknown
end

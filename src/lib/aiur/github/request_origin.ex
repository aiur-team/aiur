defmodule Aiur.GitHub.RequestOrigin do
  @moduledoc false

  @view_origin_key :aiur_github_view_origin

  @spec view_originated?() :: boolean()
  def view_originated? do
    case Process.get(@view_origin_key, :unset) do
      origin when is_boolean(origin) -> origin
      :unset -> live_view_process?(self()) or Enum.any?(List.wrap(Process.get(:"$callers")), &live_view_process?/1)
    end
  end

  @spec mark(map()) :: map()
  def mark(request), do: Map.put(request, :view_originated?, view_originated?())

  @spec carry(boolean(), (-> result)) :: result when result: term()
  def carry(origin, fun) when is_boolean(origin) and is_function(fun, 0) do
    previous = Process.put(@view_origin_key, origin)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  defp live_view_process?(pid) when is_pid(pid) do
    case Process.info(pid, :label) do
      {:label, label} -> live_view_label?(label)
      _not_running -> false
    end
  end

  defp live_view_process?(_other), do: false

  defp live_view_label?({Phoenix.LiveView, _view, _topic}), do: true
  defp live_view_label?(_other), do: false

  defp restore(nil), do: Process.delete(@view_origin_key)
  defp restore(previous), do: Process.put(@view_origin_key, previous)
end

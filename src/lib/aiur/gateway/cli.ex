defmodule Aiur.Gateway.CLI do
  @moduledoc "`aiur gateway reload`: apply `projects:` additions and removals to the running daemon."

  alias Aiur.Project.{Config, Supervisors}

  @spec reload() :: :ok
  def reload do
    if Process.whereis(Supervisors) do
      result = Supervisors.reload(Config.configured())
      IO.puts("started: " <> list(result.started))
      IO.puts("stopped: " <> list(result.stopped))
      IO.puts("unchanged: " <> list(result.unchanged))
      IO.puts("failed: " <> list(Enum.map(result.failed, fn {id, reason} -> "#{id} (#{inspect(reason, limit: 5, printable_limit: 120)})" end)))
    else
      IO.puts("this daemon started with no projects: in ~/.aiur/machine; restart it to serve projects")
    end

    :ok
  end

  defp list([]), do: "-"
  defp list(items), do: Enum.join(items, ", ")
end

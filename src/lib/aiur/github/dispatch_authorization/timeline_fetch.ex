defmodule Aiur.GitHub.DispatchAuthorization.TimelineFetch do
  @moduledoc false

  alias Aiur.GitHub.LocalHold

  @spec run((-> term()), keyword()) :: term()
  def run(fetch_fun, opts) when is_function(fetch_fun, 0) do
    LocalHold.run(
      fn -> fetch_fun.() |> unwrap_timeline_fetch_failure() end,
      LocalHold.caller_opts(opts)
    )
    |> restore_timeline_fetch_failure()
  end

  @spec run((... -> term()), list(), keyword()) :: term()
  def run(fetch_fun, args, opts) when is_function(fetch_fun) and is_list(args) do
    run(fn -> apply(fetch_fun, args) end, opts)
  end

  defp unwrap_timeline_fetch_failure({:error, {:timeline_fetch_failed, {:github, :local_hold, _} = reason}}), do: {:error, reason}
  defp unwrap_timeline_fetch_failure(result), do: result

  defp restore_timeline_fetch_failure({:error, {:github, :local_hold, _detail} = reason}), do: {:error, {:timeline_fetch_failed, reason}}
  defp restore_timeline_fetch_failure(result), do: result
end

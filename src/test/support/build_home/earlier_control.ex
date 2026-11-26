defmodule Aiur.TestSupport.BuildHome.EarlierControl do
  @moduledoc false

  def configure(params) do
    failures = :atomics.new(1, [])
    :atomics.put(failures, 1, integer(params, "fail", 0))
    Application.put_env(:aiur, __MODULE__, {params, failures})
  end

  def run(before, read) do
    {params, failures} = Application.get_env(:aiur, __MODULE__, {%{}, nil})
    Process.sleep(min(2_000, integer(params, "delay", 0)))

    if failures && :atomics.sub_get(failures, 1, 1) >= 0 do
      {:error, :unavailable}
    else
      adjust_page(read.(), before, params)
    end
  end

  defp adjust_page({:ok, page}, before, params) do
    from = if params["stall"] == "1", do: before, else: integer(params, "from", page["history"]["from"])
    {:ok, put_in(page, ["history", "from"], from)}
  end

  defp adjust_page(error, _before, _params), do: error

  defp integer(params, key, default) do
    case Integer.parse(Map.get(params, key, "")) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end
end

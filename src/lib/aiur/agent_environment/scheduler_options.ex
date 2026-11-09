defmodule Aiur.AgentEnvironment.SchedulerOptions do
  @moduledoc false

  @scheduler_option ~r/(^|\s)\+S\s+\d+(?::\d+)?/

  @spec build(pos_integer()) :: String.t()
  def build(cap) do
    System.get_env("ELIXIR_ERL_OPTIONS", "")
    |> then(&Regex.replace(@scheduler_option, &1, ""))
    |> String.split()
    |> Kernel.++(["+S", "#{cap}:#{cap}"])
    |> Enum.join(" ")
  end
end

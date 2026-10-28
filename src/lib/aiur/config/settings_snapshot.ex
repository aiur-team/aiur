defmodule Aiur.Config.SettingsSnapshot do
  @moduledoc "Process-local settings for one synchronous poll or status batch."
  @key {__MODULE__, :settings}

  @spec read((-> term())) :: term()
  def read(load), do: Process.get(@key) || load.()

  @spec run((-> result)) :: result when result: var
  def run(fun) do
    if Process.get(@key) do
      fun.()
    else
      Process.put(@key, Aiur.Config.settings())

      try do
        fun.()
      after
        Process.delete(@key)
      end
    end
  end
end

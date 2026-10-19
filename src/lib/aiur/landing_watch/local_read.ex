defmodule Aiur.LandingWatch.LocalRead do
  @moduledoc false

  alias Aiur.GitHub.LocalHold

  @spec run(function(), list(), keyword()) :: term()
  def run(read_fun, args, opts) when is_function(read_fun) and is_list(args) do
    LocalHold.run(fn -> apply(read_fun, args) end, LocalHold.caller_opts(opts))
  end
end

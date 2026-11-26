defmodule Aiur.LandingWatch.LocalRead do
  alias Aiur.GitHub.Access
  @moduledoc false

  @spec run(function(), list(), keyword()) :: term()
  def run(read_fun, args, opts) when is_function(read_fun) and is_list(args) do
    Access.with_transient_retry(fn -> apply(read_fun, args) end, Access.transient_retry_opts(opts))
  end
end

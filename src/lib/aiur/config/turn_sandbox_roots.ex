defmodule Aiur.Config.TurnSandboxRoots do
  @moduledoc """
  Owner-contributed writable roots for a runtime turn sandbox policy.

  Contributors run in registry order and stop at the first error. An empty or
  absent registry leaves the resolved policy unchanged: uninstalled components
  contribute no roots. Contributors retain their own local/remote guards.
  """

  @callback contribute(policy :: map(), settings :: struct(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end

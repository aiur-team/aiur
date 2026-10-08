defmodule Aiur.Accounts.Shim do
  @moduledoc "Harness-specific account profile operations."

  @callback profile_env(Path.t()) :: [{String.t(), String.t()}]
  @callback shared_paths() :: [String.t()]
  @callback never_shared() :: [String.t()]
  @callback login_command(Path.t()) :: {String.t(), [String.t()]}
  @callback identity(Path.t() | nil) :: map()
  @callback usage(Path.t() | nil) :: term()
  @callback session_artifacts(Path.t(), String.t(), Path.t()) :: [Path.t()]
end

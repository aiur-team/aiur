defmodule Aiur.Accounts.Shim do
  @moduledoc "Harness-specific account profile operations."

  # `false` unsets the profile variable, so `default` runs on the harness's own default profile and never inherits the daemon's (#3970).
  @callback profile_env(Path.t() | false) :: [{String.t(), String.t() | false}]
  @callback shared_paths() :: [String.t()]
  @callback never_shared() :: [String.t()]
  @callback login_command(Path.t()) :: {String.t(), [String.t()]}
  @callback identity(Path.t() | nil) :: map()
  @callback usage(Path.t() | nil) :: term()
  @callback session_artifacts(Path.t(), String.t(), Path.t()) :: [Path.t()]
  @callback profile_root() :: Path.t()

  @optional_callbacks session_artifacts: 3
end

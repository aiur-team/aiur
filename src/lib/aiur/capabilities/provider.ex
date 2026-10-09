defmodule Aiur.Capabilities.Provider do
  @moduledoc "Read-only contributions to the instance capability report. Callbacks must not mutate their sources."

  @type entry :: %{required(:state) => :available | :degraded | :unavailable | :unknown, optional(atom()) => term()}
  @type context :: %{run_shape: map(), settings: map() | :unavailable}

  @callback capability_ids() :: [String.t()]
  @callback capabilities(context()) :: %{String.t() => entry()}
  @callback sections(context()) :: %{optional(:repository | :executor) => map() | nil}
  @optional_callbacks sections: 1
end

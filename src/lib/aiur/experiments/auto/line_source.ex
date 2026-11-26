defmodule Aiur.Experiments.Auto.LineSource do
  @moduledoc false
  @callback child_spec(keyword()) :: Supervisor.child_spec()
  @callback describe() :: map()
end

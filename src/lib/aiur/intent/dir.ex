defmodule Aiur.Intent.Dir do
  @moduledoc false

  alias Aiur.Machine.Store

  @spec path() :: Path.t()
  def path, do: Application.get_env(:aiur, :intent_dir) || Path.join(Store.paths().dir, "intent")
end

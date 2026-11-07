defmodule Aiur.Intent.Dir do
  @moduledoc false

  alias Aiur.Identity.Store

  @spec path() :: Path.t()
  def path, do: Application.get_env(:aiur, :intent_dir) || Path.join(Store.dir(), "intent")
end

defmodule Aiur.Usage.Provider.Claude do
  @moduledoc false
  alias Aiur.Usage.ProviderSupport

  defstruct [:provider, :observed_at, :age_ms, :freshness, :source, fields: %{}]
  @type t :: %__MODULE__{}

  @spec read(keyword()) :: t()
  def read(opts), do: ProviderSupport.meter(__MODULE__, :claude, opts)
end

defmodule Aiur.Experiments.Registration do
  @moduledoc false
  alias Aiur.Experiments.Spec

  @spec mark(Spec.t(), DateTime.t()) :: Spec.t()
  def mark(spec, now \\ DateTime.utc_now())

  def mark(%Spec{registered_at: nil, design: %{"kind" => "before_after", "change" => %{"time" => time}}} = spec, now) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(time),
         true <- DateTime.compare(at, now) != :gt do
      %{spec | registered_at: time}
    else
      _future -> spec
    end
  end

  def mark(spec, _now), do: spec
end

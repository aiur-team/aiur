defmodule Aiur.BuildOrder.Epics.Journal do
  @moduledoc """
  Strict versioned epic journal encoding and replay.

  `build-features/epics.ndjson` sits next to `features.ndjson` and shares its
  envelope encoding. A build from before the epic level existed ignores this
  file, so rollback reads the same state directory without it.
  """

  alias Aiur.BuildOrder.Epics.{JournalValidation, Projection}
  alias Aiur.BuildOrder.Features.Journal, as: FeatureJournal

  @spec empty() :: map()
  def empty, do: Projection.empty()

  @spec encode(map()) :: map()
  defdelegate encode(record), to: FeatureJournal

  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(%{"v" => version}) when is_integer(version) and version > 1, do: {:error, :version_unsupported}
  def validate(record), do: JournalValidation.record(record)

  @spec fold(map(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate fold(projection, record), to: Projection
end

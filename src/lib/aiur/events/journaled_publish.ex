defmodule Aiur.Events.JournaledPublish do
  @moduledoc """
  Persist first, then publish with the durable id.

  Reserves a durable id, appends the normalized record to the journal, then
  fans out through `Publisher.publish_persisted/4`. A failed reservation or
  append publishes nothing; the reserved id stays a permanent gap. Callers must
  validate topic and source before calling: this does no GitHub-source rejection.

  Options: `:journal` and `:journal_dir` (required), `:source` (atom or string),
  `:publish_opts` (defaults to `[source: source]`).
  """

  # aiur:event-bus-boundary-member

  alias Aiur.Events.IdGenerator
  alias Aiur.Events.Journal
  alias Aiur.Events.Publisher
  alias Aiur.JSONSafe

  @spec publish(String.t(), map(), keyword()) :: {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  def publish(topic, payload, opts) when is_binary(topic) and is_map(payload) do
    journal = Keyword.fetch!(opts, :journal)
    dir = Keyword.fetch!(opts, :journal_dir)
    source = Keyword.get(opts, :source)

    with {:ok, id} <- IdGenerator.reserve_durable_id(),
         record = payload |> JSONSafe.normalize() |> Map.merge(%{"id" => id, "topic" => topic, "source" => source_name(source)}),
         :ok <- Journal.prepare(dir, journal),
         :ok <- Journal.append(journal, record) do
      Publisher.publish_persisted(topic, payload, id, Keyword.get(opts, :publish_opts, source: source))
    end
  end

  defp source_name(source) when is_atom(source), do: Atom.to_string(source)
  defp source_name(source), do: source
end

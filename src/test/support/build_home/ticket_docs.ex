defmodule Aiur.TestSupport.BuildHome.TicketDocs do
  @moduledoc "Frozen design issue bodies through the production detail normalizer."

  alias Aiur.BuildOrder.TicketDetail.{Normalizer, State}
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias Aiur.TrackerIdentity

  @dir Path.expand("../../fixtures/build_home", __DIR__)
  @datasets ~w(live dense newrepo noqueue offline now0 now24)

  def ignore(_identity), do: :ok

  def request(%TrackerIdentity{provider_id: "build-fixture:" <> key} = identity) do
    with [dataset, id] when dataset in @datasets <- String.split(key, ":", parts: 2),
         {:ok, row} <- FixtureSource.ticket(id, dataset: dataset),
         {:ok, text} <- File.read(Path.join(@dir, "docs-#{dataset}.json")),
         {:ok, docs} <- Jason.decode(text),
         %{"body_md" => body, "author" => author} <- docs[id],
         {:ok, data} <- FixtureSource.full(dataset: dataset),
         now = DateTime.from_unix!(data["now"], :millisecond),
         {:ok, snapshot} <- Normalizer.snapshot(identity, raw(row, identity, body, author), now: now, relationships: %{nodes: [], truncated?: false}) do
      {:ok, %State{identity: identity, generation: 1, health: :healthy, detail: snapshot, last_success_at: now, last_attempt_at: now}}
    else
      _ -> {:error, :fixture_doc_unavailable}
    end
  end

  def request(_identity), do: {:error, :fixture_doc_unavailable}

  defp raw(row, identity, body, author) do
    created = row["created"] |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    %{
      "node_id" => identity.provider_id,
      "number" => row["num"],
      "title" => row["title"],
      "body" => body,
      "user" => %{"login" => author},
      "html_url" => "https://github.com/fixture/build-home/issues/#{row["num"]}",
      "state" => "open",
      "state_reason" => nil,
      "created_at" => created,
      "updated_at" => created
    }
  end
end

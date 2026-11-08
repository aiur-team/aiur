defmodule Aiur.BrowserHarness.StreamdeckTranscript do
  @moduledoc "Browser-only retained transcript fixture over the production history reader."
  use Phoenix.Controller, formats: []
  @behaviour AiurWeb.Build.ConversationSource
  alias Aiur.Conversation.History
  alias AiurWeb.Build.ConversationSource.Entries

  def configure(conn, %{"action" => "seed"}) do
    reset()
    root = Path.join(System.tmp_dir!(), "deck-turns-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "logs"))
    System.at_exit(fn _ -> Aiur.TestCleanup.rm_rf!(root) end)
    now = DateTime.to_iso8601(DateTime.utc_now())

    lines =
      Enum.map_join(1..30, "", fn index ->
        raw = %{method: "item/completed", params: %{item: %{type: "agentMessage", text: "Seeded turn #{index}"}}}
        Jason.encode!(%{event: "notification", timestamp: now, raw: Jason.encode!(raw)}) <> "\n"
      end)

    File.write!(Path.join(root, "logs/agent.ndjson"), lines)
    :persistent_term.put({__MODULE__, :root}, root)
    Application.put_env(:aiur, :build_conversation_source, {__MODULE__, workspace: root})
    json(conn, %{turns: 30})
  end

  def configure(conn, %{"action" => "reset"}) do
    reset()
    json(conn, %{reset: true})
  end

  defp reset do
    Application.put_env(:aiur, :build_conversation_source, Aiur.TestSupport.BuildHome.FixtureConversationSource)

    if root = :persistent_term.get({__MODULE__, :root}, nil) do
      Aiur.TestCleanup.rm_rf!(root)
      :persistent_term.erase({__MODULE__, :root})
    end
  end

  @impl true
  def prepare(ref, _opts), do: {:ok, ref}
  @impl true
  def subscribe(_ref, _opts), do: :ok
  @impl true
  def unsubscribe(_ref, _opts), do: :ok

  @impl true
  def tail(_ref, nil, opts), do: project(History.workspace_paged_tail(opts[:workspace], limit: 7))
  def tail(_ref, cursor, opts), do: project(History.workspace_paged_since(opts[:workspace], cursor, limit: 7))
  @impl true
  def page(_ref, before, opts), do: project(History.workspace_paged_before(opts[:workspace], before, limit: 7))

  defp project({:ok, page}) do
    {:ok, %{state: :ended, observed_at: DateTime.utc_now(), entries: Entries.map_entries(page.entries, %{}, false), before: page.first, last: page.last, more?: page.more?}}
  end

  defp project(error), do: error
end

defmodule Aiur.Muse.StreamRenderingTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.{Transcript, View}
  alias Aiur.Opencode.ChatCompletions.DeltaRenderer

  test "native completion preserves the durable body without repeating streamed text" do
    {rendered, events} = render("hello", "hello")
    assert rendered == "hello"
    assert List.last(events).body == "hello"
  end

  test "completion appends only the suffix missing from streamed fragments" do
    {rendered, events} = render("hello", "hello world")
    assert rendered == "hello world"
    assert List.last(events).body == "hello world"
  end

  test "completion without fragments still renders the entire answer" do
    {rendered, _events} = render(nil, "hello world")
    assert rendered == "hello world"
  end

  defp render(fragment, complete) do
    item = %{"itemId" => "message", "kind" => "agentMessage", "revision" => 1, "text" => ""}
    frames = [frame("item/started", "a", %{"item" => item})]
    frames = if fragment, do: frames ++ [frame("item/delta", "b", %{"itemId" => "message", "field" => "text", "delta" => fragment})], else: frames
    frames = frames ++ [frame("item/completed", "c", %{"item" => %{item | "revision" => 2, "text" => complete}})]

    {_view, rendered, events} =
      Enum.reduce(frames, {View.new("session"), "", []}, fn native, {view, body, events} ->
        {:emit, details, view} = View.ingest(view, native)

        case Transcript.extract(details, "turn") do
          {:ok, event} ->
            delta = rendered_delta(event)

            {view, body <> delta, events ++ [event]}

          :skip ->
            {view, body, events}
        end
      end)

    {rendered, events}
  end

  defp rendered_delta(event) do
    case DeltaRenderer.transcript_delta(event, :assistant) do
      {:delta, text, :assistant} -> text
      :drop -> ""
    end
  end

  defp frame(method, cursor, params), do: %{"method" => method, "params" => Map.merge(params, %{"sessionId" => "session", "viewCursor" => cursor})}
end

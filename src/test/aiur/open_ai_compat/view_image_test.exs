defmodule Aiur.OpenAICompat.ViewImageTest do
  use ExUnit.Case, async: true
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.OpenAICompat.{CodingAgent, ImageView, Tools}

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 1, 2, 3, 4>>

  defp names(config), do: Enum.map(Tools.specs(:chat_completions, config), & &1["function"]["name"])

  test "spec offers view_image only for image-capable backends" do
    assert "view_image" in names(%{quirks: %{image_input: true}})
    refute "view_image" in names(%{quirks: %{}})
    refute "view_image" in names(%{})
  end

  test "execute refuses when the model has no image input", %{workspace: workspace} do
    File.write!(Path.join(workspace, "a.png"), @png)
    context = %{workspace: workspace, tool_executor: nil}
    assert %{"success" => false, "output" => "view_image unavailable" <> _} = Tools.execute("view_image", %{"path" => "a.png"}, context, [])
  end

  test "execute refuses escapes, oversize files and non-images", %{workspace: workspace} do
    context = %{workspace: workspace, tool_executor: nil, image_input: true}
    outside = Path.join(System.tmp_dir!(), "view-image-secret-#{System.unique_integer([:positive])}.png")
    File.write!(outside, @png)
    on_exit(fn -> File.rm(outside) end)
    File.ln_s!(outside, Path.join(workspace, "link.png"))
    File.write!(Path.join(workspace, "big.png"), @png <> :binary.copy(<<0>>, ImageView.max_bytes()))
    File.write!(Path.join(workspace, "note.png"), "just text")

    run = &Tools.execute("view_image", %{"path" => &1}, context, [])
    # The targets exist, so only containment can refuse them (not enoent).
    for path <- ["../" <> Path.basename(outside), outside, "link.png"] do
      assert %{"success" => false, "output" => "outside_workspace"} = run.(path)
    end

    assert %{"success" => false, "output" => big} = run.("big.png")
    assert big =~ "limit is #{ImageView.max_bytes()} bytes"
    assert %{"success" => false, "output" => text} = run.("note.png")
    assert text =~ "not a PNG, JPEG, GIF or WebP"
    assert text =~ "size limit #{ImageView.max_bytes()} bytes"
  end

  defp view_image_turn(workspace, instance) do
    parent = self()

    call = %{
      "id" => "call-1",
      "type" => "function",
      "function" => %{"name" => "view_image", "arguments" => ~s({"path":"frame.png"})}
    }

    reply = fn finish, message ->
      response(%{
        "id" => "r",
        "model" => "m",
        "choices" => [%{"finish_reason" => finish, "message" => Map.put(message, "role", "assistant")}],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      })
    end

    {:ok, queue} = Agent.start_link(fn -> [reply.("tool_calls", %{"content" => nil, "tool_calls" => [call]}), reply.("stop", %{"content" => "ok"})] end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance,
               api_key_fetcher: fn _ -> "k" end,
               request_fun: queue_fun(queue, parent)
             )

    assert {:ok, _} = CodingAgent.run_turn(session, "look", issue(), on_message: &send(parent, {:event, &1}))
    collect_requests(2)
  end

  defp image_parts(request) do
    for m <- request.json["messages"], m["role"] == "user", p <- List.wrap(m["content"]), is_map(p), p["type"] == "image_url", do: p
  end

  test "a view_image call puts an image part in the next request without bytes in the transcript", %{workspace: workspace} do
    File.write!(Path.join(workspace, "frame.png"), @png)
    [first, second] = view_image_turn(workspace, instance(image_input: true))

    assert "view_image" in Enum.map(first.json["tools"], & &1["function"]["name"])
    url = "data:image/png;base64," <> Base.encode64(@png)
    assert [%{"image_url" => %{"url" => ^url}}] = image_parts(second)

    assert_receive {:event, %{event: :tool_result, payload: %{name: "view_image", output: output, success: true}}}, 1000
    assert output == "attached frame.png (#{byte_size(@png)} bytes)"
    refute output =~ Base.encode64(@png)
  end

  test "a model without image input that calls view_image gets the refusal and no image", %{workspace: workspace} do
    File.write!(Path.join(workspace, "frame.png"), @png)
    [_first, second] = view_image_turn(workspace, instance([]))

    assert_receive {:event, %{event: :tool_result, payload: %{name: "view_image", output: "view_image unavailable" <> _, success: false}}}, 1000
    assert image_parts(second) == []
  end
end

Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.ControlCLI.ExecutorRequestMediaTest do
  use Aiur.DecisionStoreCase, async: false
  import ExUnit.CaptureIO
  alias Aiur.ControlCLI.ExecutorRequest
  alias Aiur.DecisionApi.PublicProjection

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    # Media paths are checked against the configured safe roots, so the image lives inside one.
    base = DecisionValidation.safe_roots() |> Enum.find(&(Path.type(&1) == :absolute))
    root = Path.join(base, "aiur-cli-media-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    image = Path.join(root, "sprite.png")
    File.write!(image, "png")

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(root)
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    %{store: start_supervised_store!(dir), image: image}
  end

  defp cli_request(store, extra) do
    params = Keyword.merge([question: "Which sprite?", options: ["a=Left", "b=Right"], executor_id: "requester", json: true], extra)
    capture_io(fn -> send(self(), {:code, ExecutorRequest.request(params, decision_store: store)}) end)
  end

  test "one image via the CLI becomes an attachment id, never a path", %{store: store, image: image} do
    output = cli_request(store, media: ["#{image},alt=Left sprite, idle,caption=Frame 1"])
    assert_received {:code, 0}
    assert {:ok, decision} = DecisionStore.get(Jason.decode!(output)["decision_id"], store)
    assert [%{kind: :image, mime_type: "image/png", alt_text: "Left sprite, idle", caption: "Frame 1", attachment_id: "med_" <> _ = id}] = decision.media

    projection = decision |> PublicProjection.encode() |> Jason.encode!()
    assert projection =~ id
    refute projection =~ image
    refute projection =~ Path.dirname(image)
  end

  test "option=ID attaches media to that option only", %{store: store, image: image} do
    output = cli_request(store, media: ["#{image},option=b,alt=Right sprite"])
    assert_received {:code, 0}
    assert {:ok, decision} = DecisionStore.get(Jason.decode!(output)["decision_id"], store)
    assert decision.media == []
    assert %{"a" => [], "b" => [%{kind: :image}]} = Map.new(decision.options, &{&1.id, &1.media})
  end

  test "the payload boundary refuses expiring URLs, paths outside safe roots and unknown options", %{store: store} do
    for {media, message} <- [
          {"https://github.com/a.png?X-Amz-Expires=60,alt=A", "locator_expires"},
          {"/etc/passwd.png,alt=A", "media"},
          {"/x.png,option=zzz,alt=A", "must name one supplied option"},
          {"/x.png,alt=", "--media attribute"}
        ] do
      assert capture_io(:stderr, fn -> send(self(), {:code, ExecutorRequest.request([question: "Q?", options: ["a=A", "b=B"], executor_id: "r", media: [media]], decision_store: store)}) end) =~
               message

      assert_received {:code, 64}
    end
  end

  test "control RPC allowlist accepts media strings" do
    assert {:ok, %{function: :command_request}} = Aiur.ControlCall.parse(~s|Aiur.AgentControlCLI.command_request(question: "Q?", media: ["/x.png,alt=A"])|)
  end
end

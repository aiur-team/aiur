defmodule Aiur.Opencode.ChatCompletions.ReplayTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Aiur.Opencode.ChatCompletions.Replay

  describe "stream/3" do
    test "message not found renders **system:** message not found then stop" do
      # No bearer token → resolve_session_for_replay returns nil
      # → nil && Db.fetch_message_with_parts(nil, id) = nil → not-found branch
      identifier = "replay-#{System.unique_integer()}"

      result = Replay.stream(conn(:post, "/"), identifier, "msg_ABCDEF")

      assert result.status == 200
      assert result.resp_body =~ "message not found"
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end
  end
end

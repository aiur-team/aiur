defmodule Aiur.AgentTools.ReadMessagesTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentTools.{Catalog, Dispatch}
  alias Aiur.AgentRunner.ToolExecutor

  test "catalog schema and executor callback expose consuming reads" do
    spec = Enum.find(Catalog.specs(), &(&1["name"] == "aiur_read_messages"))
    assert spec["inputSchema"]["additionalProperties"] == false
    assert spec["inputSchema"]["properties"]["max"] == %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 50}
    executor = ToolExecutor.build(%Aiur.Issue{id: "42", identifier: "42"}, nil, nil, %{}, message_reader: fn max -> {:ok, %{messages: [%{text: "max=#{max}"}], remaining: 2}} end)
    assert %{"success" => true, "output" => output} = executor.("aiur_read_messages", %{})
    assert Jason.decode!(output) == %{"messages" => [%{"text" => "max=50"}], "remaining" => 2}
    assert %{"success" => true, "output" => output} = executor.("aiur_read_messages", %{"max" => 1})
    assert Jason.decode!(output)["messages"] == [%{"text" => "max=1"}]
  end

  test "rejects unknown keys and invalid max before reading" do
    for args <- [%{"cursor" => 1}, %{"max" => 0}, %{"max" => 51}, %{"max" => 1.5}, %{"max" => nil}, [], "{}"] do
      result = Dispatch.execute("aiur_read_messages", args, message_reader: fn _ -> flunk("invalid call reached reader") end)
      assert result["success"] == false
      assert Jason.decode!(result["output"])["retryable"] == false
    end
  end

  test "unavailable and timed out readers return retryable failures" do
    for opts <- [[], [message_reader: fn _ -> {:error, :unavailable} end], [message_reader: fn _ -> exit({:timeout, :read}) end]] do
      result = Dispatch.execute("aiur_read_messages", %{}, opts)
      assert result["success"] == false
      assert Jason.decode!(result["output"])["retryable"] == true
    end
  end
end

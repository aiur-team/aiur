defmodule Aiur.Codex.DynamicTool.LinearGraphQLTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.LinearGraphQL

  describe "execute/3" do
    test "success on clean response" do
      response =
        LinearGraphQL.execute(
          "linear_graphql",
          %{"query" => "query { viewer { id } }"},
          linear_client: fn _q, _v, _o -> {:ok, %{"data" => %{"viewer" => %{"id" => "u1"}}}} end
        )

      assert response["success"] == true
      assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "u1"}}}
    end

    test "success false on non-empty string-key errors list" do
      response =
        LinearGraphQL.execute(
          "linear_graphql",
          %{"query" => "query { bad }"},
          linear_client: fn _q, _v, _o ->
            {:ok, %{"errors" => [%{"message" => "unknown field"}], "data" => nil}}
          end
        )

      assert response["success"] == false
    end

    test "success false on non-empty atom-key errors list" do
      response =
        LinearGraphQL.execute(
          "linear_graphql",
          %{"query" => "query { bad }"},
          linear_client: fn _q, _v, _o ->
            {:ok, %{errors: [%{message: "boom"}], data: nil}}
          end
        )

      assert response["success"] == false
    end

    test ":missing_query renders correct error" do
      response =
        LinearGraphQL.execute(
          "linear_graphql",
          %{},
          linear_client: fn _q, _v, _o -> flunk("should not be called") end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "non-empty `query` string"
    end

    test ":invalid_arguments renders correct error" do
      response =
        LinearGraphQL.execute(
          "linear_graphql",
          [:not, :valid],
          linear_client: fn _q, _v, _o -> flunk("should not be called") end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "query` and optional"
    end

    test ":invalid_variables renders correct error" do
      response =
        LinearGraphQL.execute(
          "linear_graphql",
          %{"query" => "q", "variables" => ["not", "an", "object"]},
          linear_client: fn _q, _v, _o -> flunk("should not be called") end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "variables"
    end

    test "raw string argument accepted" do
      test_pid = self()

      response =
        LinearGraphQL.execute(
          "linear_graphql",
          "  query Viewer { viewer { id } }  ",
          linear_client: fn q, v, _o ->
            send(test_pid, {:called, q, v})
            {:ok, %{"data" => %{}}}
          end
        )

      assert_received {:called, "query Viewer { viewer { id } }", %{}}
      assert response["success"] == true
    end

    test "object with variables accepted" do
      test_pid = self()

      LinearGraphQL.execute(
        "linear_graphql",
        %{"query" => "q", "variables" => %{"id" => "123"}},
        linear_client: fn q, v, _o ->
          send(test_pid, {:called, q, v})
          {:ok, %{}}
        end
      )

      assert_received {:called, "q", %{"id" => "123"}}
    end
  end
end

defmodule Aiur.Codex.DynamicTool.BlockersTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.Blockers

  describe "execute/3 — aiur_declare_blocker" do
    test "declare via injected closure succeeds with expected payload shape" do
      response =
        Blockers.execute(
          "aiur_declare_blocker",
          %{"issue_number" => 42},
          blocker_declarer: fn n -> {:ok, n} end
        )

      assert response["success"] == true
      decoded = Jason.decode!(response["output"])
      assert decoded["ok"] == true
      assert decoded["issue_number"] == 42
      assert decoded["result"] == "42"
    end

    test "atom result is rendered as a string" do
      response =
        Blockers.execute(
          "aiur_declare_blocker",
          %{"issue_number" => 5},
          blocker_declarer: fn _n -> {:ok, :already_declared} end
        )

      assert response["success"] == true
      assert Jason.decode!(response["output"])["result"] == "already_declared"
    end

    test "string issue_number is parsed" do
      response =
        Blockers.execute(
          "aiur_declare_blocker",
          %{"issue_number" => "99"},
          blocker_declarer: fn n -> {:ok, n} end
        )

      assert response["success"] == true
      assert Jason.decode!(response["output"])["issue_number"] == 99
    end

    test "non-numeric string is rejected" do
      response =
        Blockers.execute(
          "aiur_declare_blocker",
          %{"issue_number" => "abc"},
          blocker_declarer: fn _n -> {:ok, :ok} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "positive integer"
    end

    test "missing closure returns blocker_declarer_unavailable" do
      response = Blockers.execute("aiur_declare_blocker", %{"issue_number" => 1}, [])
      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end

    test "cycle_detected renders correct error" do
      response =
        Blockers.execute(
          "aiur_declare_blocker",
          %{"issue_number" => 5},
          blocker_declarer: fn _n -> {:error, :cycle_detected} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "cycle"
    end
  end

  describe "execute/3 — aiur_unblock" do
    test "unblock via injected closure succeeds" do
      response =
        Blockers.execute(
          "aiur_unblock",
          %{"issue_number" => 10},
          unblocker: fn n -> {:ok, n} end
        )

      assert response["success"] == true
      assert Jason.decode!(response["output"])["issue_number"] == 10
    end

    test "missing closure returns unblocker_unavailable" do
      response = Blockers.execute("aiur_unblock", %{"issue_number" => 1}, [])
      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end
  end

  describe "normalize_issue_number/1" do
    test "positive integer accepted" do
      assert {:ok, 42} = Blockers.normalize_issue_number(%{"issue_number" => 42})
    end

    test "string parsed and trimmed" do
      assert {:ok, 7} = Blockers.normalize_issue_number(%{"issue_number" => "  7  "})
    end

    test "string with non-numeric chars rejected" do
      assert {:error, :invalid_issue_number} =
               Blockers.normalize_issue_number(%{"issue_number" => "7x"})
    end

    test "missing key returns missing_issue_number" do
      assert {:error, :missing_issue_number} = Blockers.normalize_issue_number(%{})
    end

    test "non-map argument returns invalid_issue_number" do
      assert {:error, :invalid_issue_number} = Blockers.normalize_issue_number("not a map")
    end
  end
end

defmodule Aiur.Codex.ApprovalsTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.Approvals

  @metadata %{backend: "codex"}

  describe "maybe_handle_approval_request/8 — item/commandExecution/requestApproval" do
    test "auto-approves with acceptForSession when auto_approve_requests is true" do
      port = open_cat_port()

      try do
        payload = %{"id" => "r1", "method" => "item/commandExecution/requestApproval"}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/commandExecution/requestApproval",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert frame["result"]["decision"] == "acceptForSession"
      after
        Port.close(port)
      end
    end

    test "returns approval_required when auto_approve_requests is false" do
      payload = %{"id" => "r1", "method" => "item/commandExecution/requestApproval"}

      assert :approval_required =
               Approvals.maybe_handle_approval_request(
                 :no_port,
                 "item/commandExecution/requestApproval",
                 payload,
                 Jason.encode!(payload),
                 fn _msg -> :ok end,
                 @metadata,
                 fn _tool, _args -> %{} end,
                 false
               )
    end
  end

  describe "maybe_handle_approval_request/8 — item/fileChange/requestApproval" do
    test "auto-approves with acceptForSession decision string" do
      port = open_cat_port()

      try do
        payload = %{"id" => "r2", "method" => "item/fileChange/requestApproval"}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/fileChange/requestApproval",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert frame["result"]["decision"] == "acceptForSession"
      after
        Port.close(port)
      end
    end
  end

  describe "maybe_handle_approval_request/8 — execCommandApproval (legacy)" do
    test "auto-approves with approved_for_session decision string" do
      port = open_cat_port()

      try do
        payload = %{"id" => "r3", "method" => "execCommandApproval"}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "execCommandApproval",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert frame["result"]["decision"] == "approved_for_session"
      after
        Port.close(port)
      end
    end
  end

  describe "maybe_handle_approval_request/8 — applyPatchApproval (legacy)" do
    test "auto-approves with approved_for_session decision string" do
      port = open_cat_port()

      try do
        payload = %{"id" => "r4", "method" => "applyPatchApproval"}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "applyPatchApproval",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert frame["result"]["decision"] == "approved_for_session"
      after
        Port.close(port)
      end
    end
  end

  defp open_cat_port do
    Port.open(
      {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
      [:binary, :exit_status, {:line, 64_000}]
    )
  end

  defp read_one_frame(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
    after
      500 -> flunk("no frame received")
    end
  end
end

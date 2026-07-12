defmodule Aiur.GitHub.IssueDependenciesTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueDependencies
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    on_exit(fn -> restore_env("GITHUB_TOKEN", prev_token) end)
    :ok
  end

  describe "declare/3" do
    test "happy path: non-cyclic blocker → POSTs and returns issue" do
      request_fun = fn req ->
        cond do
          # fetch_blocker (fetch_issue_raw)
          req.method == :get and String.contains?(req.url, "/issues/80") and
              not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          # check_not_already_present: blocked_by of current
          req.method == :get and String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: []}}

          # cycle_check BFS: fetch_blocking on blocker
          req.method == :get and String.contains?(req.url, "/issues/80/dependencies/blocking") ->
            {:ok, %{status: 200, headers: [], body: []}}

          req.method == :post ->
            {:ok, %{status: 201, headers: [], body: %{"id" => 80_001, "number" => 80}}}
        end
      end

      assert {:ok, %{"id" => 80_001}} = IssueDependencies.declare(7, 80, request_fun: request_fun)
    end

    test "blocker_not_found when fetch returns 404" do
      request_fun = fn _ -> {:ok, %{status: 404, headers: [], body: ""}} end
      assert {:error, :blocker_not_found} = IssueDependencies.declare(7, 80, request_fun: request_fun)
    end

    test "cycle_detected via BFS when blocker transitively blocks current" do
      request_fun = fn req ->
        cond do
          # fetch blocker (#80)
          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          # check_not_already_present
          String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: []}}

          # 80 blocks 90
          String.contains?(req.url, "/issues/80/dependencies/blocking") ->
            {:ok, %{status: 200, headers: [], body: [%{"number" => 90}]}}

          # 90 blocks 7 (the current issue)
          String.contains?(req.url, "/issues/90/dependencies/blocking") ->
            {:ok, %{status: 200, headers: [], body: [%{"number" => 7}]}}

          # 7 blocks nothing
          String.contains?(req.url, "/issues/7/dependencies/blocking") ->
            {:ok, %{status: 200, headers: [], body: []}}
        end
      end

      assert {:error, :cycle_detected} = IssueDependencies.declare(7, 80, request_fun: request_fun)
    end

    test "idempotent: blocker already present returns :already_present" do
      request_fun = fn req ->
        cond do
          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          # already present in blocked_by
          String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: [%{"id" => 80_001, "number" => 80}]}}
        end
      end

      assert {:ok, :already_present} = IssueDependencies.declare(7, 80, request_fun: request_fun)
    end

    test "transient BFS error returns :cycle_check_inconclusive (does NOT optimistically POST)" do
      request_fun = fn req ->
        cond do
          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: []}}

          # Mid-BFS transient failure
          String.contains?(req.url, "/issues/80/dependencies/blocking") ->
            {:ok, %{status: 502, headers: [], body: ""}}
        end
      end

      assert {:error, :cycle_check_inconclusive} =
               IssueDependencies.declare(7, 80, request_fun: request_fun)
    end

    test "permission_denied on POST 403" do
      request_fun = fn req ->
        cond do
          req.method == :post ->
            {:ok, %{status: 403, headers: [], body: ""}}

          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: []}}

          String.contains?(req.url, "/issues/80/dependencies/blocking") ->
            {:ok, %{status: 200, headers: [], body: []}}
        end
      end

      assert {:error, :permission_denied} = IssueDependencies.declare(7, 80, request_fun: request_fun)
    end

    test "rate-limited POST 403 stays rate_limited" do
      request_fun = fn req ->
        cond do
          req.method == :post ->
            {:ok, rate_limited_403_response()}

          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: []}}

          String.contains?(req.url, "/issues/80/dependencies/blocking") ->
            {:ok, %{status: 200, headers: [], body: []}}
        end
      end

      assert {:error, :rate_limited} = IssueDependencies.declare(7, 80, request_fun: request_fun)
    end
  end

  describe "unblock/3" do
    test "happy path: deletes and verifies the blocker is absent" do
      request_fun = fn req ->
        cond do
          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          req.method == :delete ->
            {:ok, %{status: 204, headers: [], body: ""}}

          String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: []}}
        end
      end

      assert {:ok, :removed} = IssueDependencies.unblock(7, 80, request_fun: request_fun)
    end

    test "404 on DELETE returns :not_present (idempotent)" do
      request_fun = fn req ->
        cond do
          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          req.method == :delete ->
            {:ok, %{status: 404, headers: [], body: ""}}

          String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: []}}
        end
      end

      assert {:ok, :not_present} = IssueDependencies.unblock(7, 80, request_fun: request_fun)
    end

    test "does not report removal while the blocker remains after DELETE" do
      request_fun = fn req ->
        cond do
          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          req.method == :delete ->
            {:ok, %{status: 204, headers: [], body: ""}}

          String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: [%{"id" => 80_001, "number" => 80}]}}
        end
      end

      assert {:error, :dependency_still_present} =
               IssueDependencies.unblock(7, 80, request_fun: request_fun)
    end

    test "distinguishes a malformed DELETE 404 when the blocker remains" do
      request_fun = fn req ->
        cond do
          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          req.method == :delete ->
            {:ok, %{status: 404, headers: [], body: ""}}

          String.contains?(req.url, "/issues/7/dependencies/blocked_by") ->
            {:ok, %{status: 200, headers: [], body: [%{"id" => 80_001, "number" => 80}]}}
        end
      end

      assert {:error, :dependency_still_present} =
               IssueDependencies.unblock(7, 80, request_fun: request_fun)
    end

    test "rate-limited DELETE 403 stays rate_limited" do
      request_fun = fn req ->
        cond do
          String.contains?(req.url, "/issues/80") and not String.contains?(req.url, "dependencies") ->
            {:ok, %{status: 200, headers: [], body: %{"id" => 80_001, "number" => 80}}}

          req.method == :delete ->
            {:ok, rate_limited_403_response()}
        end
      end

      assert {:error, :rate_limited} = IssueDependencies.unblock(7, 80, request_fun: request_fun)
    end
  end

  defp rate_limited_403_response do
    %{
      status: 403,
      headers: [{"x-ratelimit-remaining", "0"}],
      body: %{"message" => "API rate limit exceeded"}
    }
  end
end

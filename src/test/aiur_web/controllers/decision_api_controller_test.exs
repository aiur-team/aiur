defmodule AiurWeb.DecisionApiControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.DecisionApiController

  @actor %{kind: :supervisor, id: "supervising-agent"}

  defmodule FakeDecisionApi do
    def list(params, opts), do: respond(:list, [params, opts])
    def get(decision_id, opts), do: respond(:get, [decision_id, opts])
    def enrich(decision_id, payload, opts), do: respond(:enrich, [decision_id, payload, opts])
    def decide(decision_id, payload, opts), do: respond(:decide, [decision_id, payload, opts])
    def revise(decision_id, payload, opts), do: respond(:revise, [decision_id, payload, opts])

    defp respond(operation, args) do
      send(self(), {:decision_api_called, operation, args})
      Process.get({__MODULE__, operation}, {:error, :store_unavailable})
    end
  end

  test "list and get return machine-readable canonical payloads" do
    Process.put({FakeDecisionApi, :list}, {:ok, %{"decisions" => [], "pagination" => %{"total" => 0}}})
    list_conn = DecisionApiController.index(api_conn(:get), %{"limit" => "5"})

    assert list_conn.status == 200
    assert Jason.decode!(list_conn.resp_body)["pagination"]["total"] == 0
    assert_receive {:decision_api_called, :list, [%{"limit" => "5"}, opts]}
    assert opts[:actor] == @actor
    assert opts[:store] == :fake_store

    Process.put(
      {FakeDecisionApi, :get},
      {:ok,
       %{
         "decision_id" => "dec_known",
         "scope" => %{"kind" => "retained", "label" => "All retained decisions"},
         "health" => %{"status" => "partial", "partial" => true, "reason" => "retained_store_partial"}
       }}
    )

    get_conn = DecisionApiController.show(api_conn(:get), %{"decision_id" => "dec_known"})

    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body)["decision_id"] == "dec_known"
    assert Jason.decode!(get_conn.resp_body)["health"]["status"] == "partial"
    assert_receive {:decision_api_called, :get, ["dec_known", _opts]}
  end

  test "v1 list forwards documented offset pagination unchanged" do
    Process.put({FakeDecisionApi, :list}, {:ok, %{"decisions" => [], "pagination" => %{"offset" => 50}}})

    response =
      DecisionApiController.index(api_conn(:get), %{
        "limit" => "200",
        "offset" => "50",
        "ticket" => "1088"
      })

    assert response.status == 200

    assert_receive {:decision_api_called, :list, [%{"limit" => "200", "offset" => "50", "ticket" => "1088"}, _opts]}
  end

  test "partial retained data never reports a missing Decision as absent" do
    Process.put(
      {FakeDecisionApi, :get},
      {:error, {:indeterminate, %{status: :partial, partial?: true, reason: :retained_store_partial, label: "Partial retained Decision data"}}}
    )

    response = DecisionApiController.show(api_conn(:get), %{"decision_id" => "dec_unknown"})
    body = Jason.decode!(response.resp_body)

    assert response.status == 503
    assert body["error"]["code"] == "decision_presence_indeterminate"
    assert body["scope"] == %{"kind" => "retained", "label" => "All retained decisions"}

    assert body["health"] == %{
             "status" => "partial",
             "partial" => true,
             "reason" => "retained_store_partial",
             "label" => "Partial retained Decision data"
           }
  end

  test "mutations keep the path identity authoritative and preserve service status" do
    cases = [
      {:enrich, :enrich, %{"status" => "accepted"}, 202},
      {:decide, :decide, %{"status" => "duplicate"}, 200},
      {:revise, :revise, %{"status" => "accepted", "revision_result" => "recorded"}, 202}
    ]

    for {action, operation, result, expected_status} <- cases do
      Process.put({FakeDecisionApi, operation}, {:ok, result})

      params = %{
        "decision_id" => "dec_path",
        "expected_version" => 2,
        "actor" => %{"kind" => "operator"}
      }

      response = apply(DecisionApiController, action, [api_conn(:post), params])
      assert response.status == expected_status
      assert Jason.decode!(response.resp_body) == result

      assert_receive {:decision_api_called, ^operation, ["dec_path", payload, opts]}
      refute Map.has_key?(payload, "decision_id")
      assert payload["actor"] == %{"kind" => "operator"}
      assert opts[:actor] == @actor
    end
  end

  test "maps domain failures to stable redacted HTTP errors" do
    cases = [
      {:not_found, 404, "decision_not_found"},
      {{:delegation_forbidden, %{reasons: [:human_required]}}, 403, "supervisor_forbidden"},
      {{:delegation_invalid, {:rationale, :missing}}, 422, "invalid_request"},
      {{:enrichment_invalid, {:forbidden_fields, ["authority"]}}, 422, "invalid_request"},
      {{:decision_invalid, {:artifacts, :artifact_url_insecure_scheme}}, 422, "invalid_request"},
      {{:conflict, {:stale_version, 1, 2}}, 409, "decision_conflict"},
      {{:answer_invalid, {:supervisor_basis, :decision_mismatch}}, 409, "decision_conflict"},
      {:answer_missing, 409, "decision_conflict"},
      {{:store_unavailable, {:secret, "do-not-leak"}}, 503, "decision_service_unavailable"}
    ]

    for {reason, expected_status, expected_code} <- cases do
      Process.put({FakeDecisionApi, :decide}, {:error, reason})

      response =
        DecisionApiController.decide(api_conn(:post), %{
          "decision_id" => "dec_known",
          "expected_version" => 1
        })

      body = Jason.decode!(response.resp_body)
      assert response.status == expected_status
      assert body["error"]["code"] == expected_code
      refute response.resp_body =~ "do-not-leak"
    end
  end

  test "method and route errors use the shared JSON envelope" do
    method = DecisionApiController.method_not_allowed(api_conn(:patch), %{})
    missing = DecisionApiController.not_found(api_conn(:get), %{})

    assert method.status == 405
    assert Jason.decode!(method.resp_body)["error"]["code"] == "method_not_allowed"
    assert missing.status == 404
    assert Jason.decode!(missing.resp_body)["error"]["code"] == "not_found"
  end

  defp api_conn(method) do
    method
    |> conn("/")
    |> assign(:decision_actor, @actor)
    |> put_private(:decision_api, FakeDecisionApi)
    |> put_private(:decision_api_opts, store: :fake_store)
  end
end

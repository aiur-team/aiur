defmodule AiurWeb.CommandsApiControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Aiur.Commands.{ComponentState, Scope}
  alias AiurWeb.CommandsApiController

  @secret String.duplicate("s", 64)

  defmodule FakeHostApi do
    def list(scope, params, opts) do
      send(self(), {:host_api_called, :list, [scope, params, opts]})
      Process.get({__MODULE__, :list}, {:ok, %{"commands" => [], "count" => 0}})
    end

    def show(scope, decision_id, opts) do
      send(self(), {:host_api_called, :show, [scope, decision_id, opts]})
      Process.get({__MODULE__, :show}, {:error, :not_found})
    end

    def answer(scope, decision_id, payload, opts) do
      send(self(), {:host_api_called, :answer, [scope, decision_id, payload, opts]})
      Process.get({__MODULE__, :answer}, {:error, :not_found})
    end

    def reject(scope, decision_id, payload, opts) do
      send(self(), {:host_api_called, :reject, [scope, decision_id, payload, opts]})
      Process.get({__MODULE__, :reject}, {:error, :not_found})
    end

    def media(scope, decision_id, attachment_id, opts) do
      send(self(), {:host_api_called, :media, [scope, decision_id, attachment_id, opts]})
      Process.get({__MODULE__, :media}, {:error, :not_found})
    end
  end

  test "a scoped list returns the component payload" do
    Process.put({FakeHostApi, :list}, {:ok, %{"commands" => [ComponentState.from_projection(%{"decision_id" => "dec_1"})], "count" => 1}})

    conn = scoped_conn(:get) |> CommandsApiController.index(%{"limit" => "10"})

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["count"] == 1
    assert [%{"state" => "pending"}] = body["commands"]

    assert_receive {:host_api_called, :list, [scope, %{"limit" => "10"}, opts]}, 1_000
    assert scope.tickets == ["42"]
    assert opts[:store] == :fake_store
  end

  test "an out-of-scope or missing Command is a 404, never a 403 that confirms it exists" do
    conn = scoped_conn(:get) |> CommandsApiController.show(%{"decision_id" => "dec_hidden"})

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "command_not_found"
  end

  test "an allowed answer returns the updated component" do
    Process.put(
      {FakeHostApi, :answer},
      {:ok, %{"command" => ComponentState.from_projection(%{"decision_id" => "dec_1", "decision_status" => "decided"})}}
    )

    conn = scoped_conn(:post) |> CommandsApiController.answer(%{"decision_id" => "dec_1", "option_id" => "approve"})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["command"]["state"] == "answered"
    assert_receive {:host_api_called, :answer, [_scope, "dec_1", payload, _opts]}, 1_000
    assert payload["option_id"] == "approve"
    refute Map.has_key?(payload, "decision_id")
  end

  test "reject passes the reason to the host API and an out-of-scope id is the same 404" do
    conn = scoped_conn(:post) |> CommandsApiController.reject(%{"decision_id" => "dec_hidden", "reason" => "wrong"})
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "command_not_found"

    Process.put({FakeHostApi, :reject}, {:ok, %{"command" => %{"state" => "rejected"}}})
    conn = scoped_conn(:post) |> CommandsApiController.reject(%{"decision_id" => "dec_1", "reason" => "wrong"})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["command"]["state"] == "rejected"
    assert_receive {:host_api_called, :reject, [_scope, "dec_1", %{"reason" => "wrong"} = payload, _opts]}, 1_000
    refute Map.has_key?(payload, "decision_id")
  end

  test "a stale version answer is a 409 with a conflict component" do
    Process.put({FakeHostApi, :answer}, {:error, {:conflict, {:stale_version, 1, 2}}})

    conn = scoped_conn(:post) |> CommandsApiController.answer(%{"decision_id" => "dec_1"})

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "command_conflict"
    assert body["command"]["state"] == "conflict"
  end

  test "an invalid answer is a 422 with a validation component" do
    Process.put({FakeHostApi, :answer}, {:error, {:invalid_answer, {:idempotency_key, :missing}}})

    conn = scoped_conn(:post) |> CommandsApiController.answer(%{"decision_id" => "dec_1"})

    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "invalid_request"
    assert body["command"]["reason"] == "validation_failed"
  end

  test "an unavailable store is a 503" do
    Process.put({FakeHostApi, :list}, {:error, :store_unavailable})

    conn = scoped_conn(:get) |> CommandsApiController.index(%{})

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "commands_unavailable"
  end

  test "a scoped media read redirects to the item's public URL" do
    Process.put(
      {FakeHostApi, :media},
      {:ok, %{kind: :image, mime_type: "image/png", locator: %{kind: :url, value: "https://github.com/a/b.png"}}}
    )

    conn =
      scoped_conn(:get)
      |> CommandsApiController.media(%{"decision_id" => "dec_1", "attachment_id" => "med_abc"})

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["https://github.com/a/b.png"]

    assert_receive {:host_api_called, :media, [scope, "dec_1", "med_abc", opts]}, 1_000
    assert scope.tickets == ["42"]
    assert opts[:store] == :fake_store
  end

  test "an out-of-scope or missing media attachment is a 404" do
    conn =
      scoped_conn(:get)
      |> CommandsApiController.media(%{"decision_id" => "dec_hidden", "attachment_id" => "med_abc"})

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "media_not_found"
  end

  test "an unavailable store is a 503 on a media read" do
    Process.put({FakeHostApi, :media}, {:error, :store_unavailable})

    conn =
      scoped_conn(:get)
      |> CommandsApiController.media(%{"decision_id" => "dec_1", "attachment_id" => "med_abc"})

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "decision_store_unavailable"
  end

  test "a request without a verified scope assigns nothing and is refused" do
    conn = conn(:get, "/api/v1/commands") |> Map.put(:private, %{host_api: FakeHostApi})

    conn = CommandsApiController.index(conn, %{})

    assert conn.status == 401
    refute_receive {:host_api_called, _operation, _args}, 100
  end

  test "minting a scope returns a verifiable token and the scope description" do
    conn =
      conn(:post, "/api/v1/commands/scope")
      |> Map.put(:private, %{command_scope_secret: @secret})
      |> CommandsApiController.mint_scope(%{"principal" => "player-7", "tickets" => ["42"], "expires_in" => 120})

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["scope"] == %{"kind" => "tickets", "label" => "Ticket-scoped Commands", "tickets" => ["42"]}

    assert {:ok, scope} = Scope.verify(body["token"], secret: @secret)
    assert scope.subject == "player-7"
    assert scope.tickets == ["42"]
  end

  test "minting a label scope returns a grant that carries the labels" do
    conn =
      conn(:post, "/api/v1/commands/scope")
      |> Map.put(:private, %{command_scope_secret: @secret})
      |> CommandsApiController.mint_scope(%{"principal" => "player-7", "labels" => ["Game:Chess"]})

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["scope"] == %{"kind" => "tickets", "label" => "Ticket-scoped Commands", "tickets" => [], "labels" => ["game:chess"]}

    assert {:ok, scope} = Scope.verify(body["token"], secret: @secret)
    assert scope.subject == "player-7"
    assert scope.tickets == []
    assert MapSet.to_list(scope.label_set) == ["game:chess"]
  end

  test "minting rejects an invalid principal or empty ticket set" do
    assert mint_status(%{"principal" => "", "tickets" => ["42"]}) == 422
    assert mint_status(%{"principal" => "player-7", "tickets" => []}) == 422
    assert mint_status(%{"principal" => "player-7", "tickets" => ["42"], "expires_in" => 0}) == 422
    assert mint_status(%{"principal" => "player-7"}) == 422
    assert mint_status(%{"principal" => "player-7", "labels" => ["nocolon"]}) == 422
    assert mint_status(%{"principal" => "player-7", "labels" => "game:chess"}) == 422
  end

  defp mint_status(params) do
    conn =
      conn(:post, "/api/v1/commands/scope")
      |> Map.put(:private, %{command_scope_secret: @secret})
      |> CommandsApiController.mint_scope(params)

    conn.status
  end

  defp scoped_conn(method) do
    {:ok, %{scope: scope}} = Scope.mint("player-7", ["42"], secret: @secret)

    method
    |> conn("/api/v1/commands")
    |> assign(:command_scope, scope)
    |> Map.put(:private, %{host_api: FakeHostApi, host_api_opts: [store: :fake_store]})
  end
end

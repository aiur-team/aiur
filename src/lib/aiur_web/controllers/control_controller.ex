defmodule AiurWeb.ControlController do
  @moduledoc "Runs the versioned, allowlisted machine control-call contract."

  use Phoenix.Controller, formats: [:json]

  alias Aiur.ControlCall
  alias Aiur.ControlCall.Audit
  alias Aiur.ControlCall.ReplayStore
  alias Aiur.Gateway.Grants
  alias Plug.Conn

  require Logger

  @default_timeout_ms 10_000
  @executor_wait_timeout_ms 660_000
  @regular_timeout_ms 30_000
  @request_id ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  @origin_gateway ~r/^[A-Za-z0-9._-]{1,64}$/

  @spec run(Conn.t(), map()) :: Conn.t()
  def run(conn, params) do
    started = System.monotonic_time(:millisecond)
    expression = Map.get(params, "expression")
    requested_scope = max_scope(params["max_scope"])
    conn = conn |> assign(:request_id, request_id(params)) |> assign(:origin_gateway, params["origin_gateway"])

    cond do
      request_contract(params) != :ok -> refusal(conn, expression, nil, :parse_error, 422, started)
      not is_binary(expression) -> refusal(conn, nil, nil, :parse_error, 422, started)
      true -> execute_expression(conn, params, expression, requested_scope, started)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    audit_refusal(conn, nil, nil, "refused", nil, 0)
    error(conn, 405, "method_not_allowed", nil, nil)
  end

  defp request_contract(params) do
    valid_scope = is_nil(params["max_scope"]) or params["max_scope"] in ["read", "write"]
    valid_timeout = is_nil(params["timeout_ms"]) or (is_integer(params["timeout_ms"]) and params["timeout_ms"] > 0)

    valid_version = params["contract_version"] in ControlCall.accepted_call_versions()

    if params["contract"] == ControlCall.call_type() and valid_version and valid_scope and valid_timeout and valid_origin?(params["origin_gateway"]),
      do: :ok,
      else: {:error, :parse_error}
  end

  defp valid_origin?(nil), do: true
  defp valid_origin?(origin), do: is_binary(origin) and Regex.match?(@origin_gateway, origin)

  defp execute_expression(conn, params, expression, requested_scope, started) do
    case ControlCall.parse(expression, remote: true, max_scope: :write) do
      {:ok, call} ->
        cond do
          not allowed_scope?(conn.assigns.token_scope, requested_scope, call.scope) ->
            refusal(conn, expression, call, :scope_denied, 403, started)

          not category_granted?(conn, call) ->
            refusal_code(conn, expression, call, 403, "category_not_granted: #{call.category}", started)

          reason = peer_refusal(conn, call) ->
            grant_refusal(conn, expression, call, reason, started)

          call.scope == :write and not dashboard_writable?() ->
            refusal(conn, expression, call, :dashboard_read_only, 403, started)

          true ->
            execute_call(conn, params, expression, call, started)
        end

      {:error, :grants_are_local} ->
        grant_refusal(conn, expression, nil, :grants_are_local, started)

      {:error, reason} ->
        status = if reason == :scope_exceeds_max, do: 403, else: 422
        refusal(conn, expression, nil, reason, status, started)
    end
  end

  # A peer-bound token is also limited by what this gateway's registry lets that peer do.
  defp peer_refusal(%{assigns: %{token_peer: peer}} = conn, call) when is_binary(peer) do
    case Grants.allowed?(peer, conn.assigns[:token_name], call.category) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  defp peer_refusal(_conn, _call), do: nil

  defp grant_refusal(conn, expression, call, reason, started) do
    {code, event} = grant_code(reason)

    case audit(conn, expression, call, "refused", nil, elapsed(started), %{event: event, reason: code}) do
      :ok -> error(conn, 403, code, nil, nil)
      {:error, _} -> error(conn, 503, "audit_unavailable", nil, nil)
    end
  end

  defp grant_code(:grants_are_local), do: {"grants_are_local", "grants_are_local_refused"}
  defp grant_code({:category_not_granted, category}), do: {"category_not_granted: #{category}", "category_not_granted_refused"}
  defp grant_code(reason), do: {to_string(reason), "category_not_granted_refused"}

  defp category_granted?(conn, call), do: to_string(call.category) in (conn.assigns[:token_categories] || [])

  defp allowed_scope?(token_scope, requested_scope, :write), do: token_scope == "write" and requested_scope == :write
  defp allowed_scope?(_token_scope, _requested_scope, _call_scope), do: true

  defp execute_call(conn, params, expression, call, started) do
    timeout_ms = capped_timeout(call, params["timeout_ms"])

    case claim(conn.assigns.token_name, params, call, expression) do
      :unstored -> run_call(conn, expression, call, timeout_ms, started, nil)
      {:stored, token, id} -> run_call(conn, expression, call, timeout_ms, started, {token, id})
      :invalid_request_id -> refusal_code(conn, expression, call, 422, "invalid_request_id", started)
      {:replay, status, body, original} -> replayed(conn, expression, call, status, body, original, started)
      {:refuse, status, code} -> refusal_code(conn, expression, call, status, code, started)
    end
  end

  # Only version 2 writes carrying a request_id are replay-safe; everything else runs as before.
  defp claim(token, %{"contract_version" => 2, "request_id" => id}, %{scope: :write}, expression) do
    if is_binary(id) and Regex.match?(@request_id, id) do
      case ReplayStore.claim(token, id, :crypto.hash(:sha256, expression) |> Base.encode16(case: :lower)) do
        :new -> {:stored, token, id}
        {:replay, _, _, _} = replay -> replay
        :in_progress -> {:refuse, 409, "request_in_progress"}
        :reused -> {:refuse, 422, "request_id_reused"}
        {:error, :full} -> {:refuse, 503, "replay_store_full"}
        {:error, :unavailable} -> {:refuse, 503, "replay_store_unavailable"}
      end
    else
      :invalid_request_id
    end
  end

  defp claim(_token, _params, _call, _expression), do: :unstored

  defp run_call(conn, expression, call, timeout_ms, started, stored) do
    case ControlCall.run(call, timeout_ms, "token:" <> conn.assigns.token_name) do
      {:ok, output} ->
        successful_call(conn, expression, call, output, started, stored)

      {:error, :timeout} ->
        timed_out(conn, expression, call, timeout_ms, started, stored)
    end
  end

  defp successful_call(conn, expression, call, output, started, stored) do
    elapsed_ms = elapsed(started)
    exit_code = exit_code(output)
    outcome = if exit_code == 0, do: "ok", else: "error"
    body = output |> result_body(elapsed_ms) |> wire(stored)
    store_finish(stored, 200, body, outcome)

    if call.scope == :write do
      case audit(conn, expression, call, outcome, exit_code, elapsed_ms) do
        :ok -> json(conn, body)
        {:error, _} -> error(conn, 503, "audit_unavailable", nil, nil)
      end
    else
      json(conn, body)
    end
  end

  defp timed_out(conn, expression, call, timeout_ms, started, stored) do
    elapsed_ms = elapsed(started)
    outcome = if call.scope == :write, do: "timeout_unknown", else: "refused"
    store_finish(stored, 504, error_body("timeout", nil, timeout_ms, 504), outcome)

    case audit_refusal(conn, expression, call, outcome, nil, elapsed_ms) do
      :ok -> error(conn, 504, "timeout", nil, timeout_ms)
      {:error, _} -> error(conn, 503, "audit_unavailable", nil, nil)
    end
  end

  # A stored response is sent in the exact shape a replay reads back (JSON round trip), so both are byte-equal.
  defp wire(body, nil), do: body
  defp wire(body, _stored), do: body |> Jason.encode!() |> Jason.decode!()

  # The caller still gets its answer if the store write fails: the call ran, and boot marks the entry outcome_unknown.
  defp store_finish(nil, _status, _body, _outcome), do: :ok

  defp store_finish({token, id}, status, body, outcome) do
    with {:error, reason} <- ReplayStore.finish(token, id, status, body, outcome) do
      Logger.error("control replay store could not record the result for #{id}: #{inspect(reason)}")
    end
  end

  defp replayed(conn, expression, call, status, body, original, started) do
    case audit(conn, expression, call, "replayed", nil, elapsed(started), %{original_outcome: original}) do
      :ok -> conn |> put_resp_header("x-aiur-replayed", "true") |> put_status(status) |> json(body)
      {:error, _} -> error(conn, 503, "audit_unavailable", nil, nil)
    end
  end

  defp refusal_code(conn, expression, call, status, code, started) do
    case audit_refusal(conn, expression, call, "refused", nil, elapsed(started)) do
      :ok -> error(conn, status, code, nil, nil)
      {:error, _} -> error(conn, 503, "audit_unavailable", nil, nil)
    end
  end

  defp request_id(%{"contract_version" => 2, "request_id" => id}) when is_binary(id), do: if(Regex.match?(@request_id, id), do: id)
  defp request_id(_params), do: nil

  defp capped_timeout(call, requested) do
    cap = if call.module == Aiur.AgentControlCLI and call.function == :executor_wait, do: @executor_wait_timeout_ms, else: @regular_timeout_ms
    requested = if is_integer(requested) and requested > 0, do: requested, else: @default_timeout_ms
    min(requested, cap)
  end

  defp refusal(conn, expression, call, reason, status, started) do
    case audit_refusal(conn, expression, call, "refused", nil, elapsed(started)) do
      :ok ->
        code = if status == 403, do: "scope_denied", else: "call_refused"
        error(conn, status, code, reason, nil)

      {:error, _} ->
        error(conn, 503, "audit_unavailable", nil, nil)
    end
  end

  defp audit_refusal(conn, expression, call, outcome, exit_code, elapsed_ms) do
    audit(conn, expression, call, outcome, exit_code, elapsed_ms)
  end

  defp audit(conn, expression, call, outcome, exit_code, elapsed_ms, extra \\ %{}) do
    Audit.append(
      Map.merge(extra, %{
        at: DateTime.utc_now() |> DateTime.to_iso8601(),
        request_id: conn.assigns[:request_id],
        origin_gateway: conn.assigns[:origin_gateway],
        actor: "token:" <> (conn.assigns[:token_name] || "unknown"),
        token: conn.assigns[:token_name] || "unknown",
        scope: conn.assigns[:token_scope] || "unknown",
        peer: conn.assigns[:token_peer],
        category: call && call.category,
        call: call_name(call),
        expression_sha256: if(is_binary(expression), do: :crypto.hash(:sha256, expression) |> Base.encode16(case: :lower)),
        outcome: outcome,
        exit_code: exit_code,
        elapsed_ms: elapsed_ms,
        remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string()
      })
    )
  end

  defp result_body(output, elapsed_ms) do
    Map.merge(Aiur.Gateway.Identity.current(), %{
      contract: ControlCall.result_type(),
      contract_version: ControlCall.result_version(),
      instance_id: Aiur.Identity.instance_id(),
      build: build(),
      output: output,
      elapsed_ms: elapsed_ms
    })
  end

  defp error(conn, status, code, reason, timeout_ms), do: conn |> put_status(status) |> json(error_body(code, reason, timeout_ms, status))

  defp error_body(code, reason, timeout_ms, status) do
    body = %{error: %{code: code}}
    body = if reason, do: put_in(body, [:error, :reason], reason_name(reason)), else: body
    body = if match?({:unknown_on_build, _}, reason), do: put_in(body, [:error, :detail], elem(reason, 1)), else: body
    body = if code == "scope_denied", do: put_in(body, [:error, :required_scope], "write"), else: body
    body = if timeout_ms, do: put_in(body, [:error, :timeout_ms], timeout_ms), else: body
    if status == 422, do: put_in(body, [:error, :build], build()), else: body
  end

  defp build do
    stamp = Aiur.BuildStamp.read()
    %{version: to_string(Application.spec(:aiur, :vsn) || "unknown"), commit: Map.get(stamp, "source_sha", "unknown")}
  end

  defp call_name(%{module: module, function: function, args: args}), do: "#{inspect(module)}.#{function}/#{length(args)}"
  defp call_name(_call), do: "unparsed"

  defp reason_name({:unknown_on_build, _name}), do: "unknown_on_build"
  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp max_scope("read"), do: :read
  defp max_scope(_), do: :write

  defp dashboard_writable? do
    AiurWeb.EndpointConfig.get(:dashboard_writable) == true
  rescue
    _ -> false
  end

  defp elapsed(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp exit_code(output) do
    case Regex.run(~r/__AIUR_CONTROL_EXIT__:(-?\d+)/, output) do
      [_, code] -> String.to_integer(code)
      _ -> 1
    end
  end
end

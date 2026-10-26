defmodule AiurWeb.ControlController do
  @moduledoc "Runs the versioned, allowlisted machine control-call contract."

  use Phoenix.Controller, formats: [:json]

  alias Aiur.ControlCall
  alias Aiur.ControlCall.Audit
  alias Plug.Conn

  @default_timeout_ms 10_000
  @executor_wait_timeout_ms 660_000
  @regular_timeout_ms 30_000

  @spec run(Conn.t(), map()) :: Conn.t()
  def run(conn, params) do
    started = System.monotonic_time(:millisecond)
    expression = Map.get(params, "expression")
    requested_scope = max_scope(params["max_scope"])

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

    if params["contract"] == ControlCall.call_type() and params["contract_version"] == ControlCall.call_version() and valid_scope and valid_timeout,
      do: :ok,
      else: {:error, :parse_error}
  end

  defp execute_expression(conn, params, expression, requested_scope, started) do
    case ControlCall.parse(expression, remote: true, max_scope: :write) do
      {:ok, call} ->
        cond do
          not allowed_scope?(conn.assigns.token_scope, requested_scope, call.scope) ->
            refusal(conn, expression, call, :scope_denied, 403, started)

          call.scope == :write and not dashboard_writable?() ->
            refusal(conn, expression, call, :dashboard_read_only, 403, started)

          true ->
            execute_call(conn, params, expression, call, started)
        end

      {:error, reason} ->
        status = if reason == :scope_exceeds_max, do: 403, else: 422
        refusal(conn, expression, nil, reason, status, started)
    end
  end

  defp allowed_scope?(token_scope, requested_scope, :write), do: token_scope == "write" and requested_scope == :write
  defp allowed_scope?(_token_scope, _requested_scope, _call_scope), do: true

  defp execute_call(conn, params, expression, call, started) do
    timeout_ms = capped_timeout(call, params["timeout_ms"])

    case ControlCall.run(call, timeout_ms, "token:" <> conn.assigns.token_name) do
      {:ok, output} ->
        successful_call(conn, expression, call, output, started)

      {:error, :timeout} ->
        timed_out(conn, expression, call, timeout_ms, started)
    end
  end

  defp successful_call(conn, expression, call, output, started) do
    elapsed_ms = elapsed(started)
    exit_code = exit_code(output)
    outcome = if exit_code == 0, do: "ok", else: "error"

    if call.scope == :write do
      case audit(conn, expression, call, outcome, exit_code, elapsed_ms) do
        :ok -> result(conn, output, elapsed_ms)
        {:error, _} -> error(conn, 503, "audit_unavailable", nil, nil)
      end
    else
      result(conn, output, elapsed_ms)
    end
  end

  defp timed_out(conn, expression, call, timeout_ms, started) do
    elapsed_ms = elapsed(started)
    outcome = if call.scope == :write, do: "timeout_unknown", else: "refused"

    case audit_refusal(conn, expression, call, outcome, nil, elapsed_ms) do
      :ok -> error(conn, 504, "timeout", nil, timeout_ms)
      {:error, _} -> error(conn, 503, "audit_unavailable", nil, nil)
    end
  end

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

  defp audit(conn, expression, call, outcome, exit_code, elapsed_ms) do
    Audit.append(%{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      token: conn.assigns[:token_name] || "unknown",
      scope: conn.assigns[:token_scope] || "unknown",
      call: call_name(call),
      expression_sha256: if(is_binary(expression), do: :crypto.hash(:sha256, expression) |> Base.encode16(case: :lower)),
      outcome: outcome,
      exit_code: exit_code,
      elapsed_ms: elapsed_ms,
      remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string()
    })
  end

  defp result(conn, output, elapsed_ms) do
    json(conn, %{
      contract: ControlCall.result_type(),
      contract_version: ControlCall.result_version(),
      instance_id: Aiur.Identity.instance_id(),
      build: build(),
      output: output,
      elapsed_ms: elapsed_ms
    })
  end

  defp error(conn, status, code, reason, timeout_ms) do
    body = %{error: %{code: code}}
    body = if reason, do: put_in(body, [:error, :reason], reason_name(reason)), else: body
    body = if match?({:unknown_on_build, _}, reason), do: put_in(body, [:error, :detail], elem(reason, 1)), else: body
    body = if code == "scope_denied", do: put_in(body, [:error, :required_scope], "write"), else: body
    body = if timeout_ms, do: put_in(body, [:error, :timeout_ms], timeout_ms), else: body
    body = if status == 422, do: put_in(body, [:error, :build], build()), else: body
    conn |> put_status(status) |> json(body)
  end

  defp build do
    stamp = Aiur.BuildStamp.read()
    %{version: to_string(Application.spec(:aiur, :vsn) || "unknown"), commit: Map.get(stamp, "source_sha", "unknown")}
  end

  defp call_name(%{module: module, function: function, args: args}), do: "#{inspect(module)}.#{function}/#{length(args)}"
  defp call_name(_call), do: "unparsed"

  defp reason_name({:unknown_on_build, _name}), do: "unknown_on_build"
  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name(_reason), do: "parse_error"

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

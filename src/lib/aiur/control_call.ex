defmodule Aiur.ControlCall do
  @moduledoc """
  Parses and runs the literal control expressions accepted by remote clients.

  Input is never evaluated. The AST walker admits only literals and the single
  `Base.decode64!/1` constructor used by the CLI engine.
  """

  alias Aiur.ControlCall.Allowlist
  alias Aiur.ControlCall.Literal

  @call_type "aiur.control.call"
  @call_version 1
  @result_type "aiur.control.result"
  @result_version 1
  @actor_key {__MODULE__, :actor}
  @exit_marker "__AIUR_CONTROL_EXIT__:"
  @error_marker "__AIUR_CONTROL_ERROR__:"

  @spec call_type() :: binary()
  def call_type, do: @call_type

  @spec call_version() :: pos_integer()
  def call_version, do: @call_version

  @spec result_type() :: binary()
  def result_type, do: @result_type

  @spec result_version() :: pos_integer()
  def result_version, do: @result_version

  @spec parse(binary(), keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def parse(expression, opts \\ [])

  def parse(expression, opts) when is_binary(expression) do
    _ = Allowlist.entries()

    with {:ok, ast} <- parse_ast(expression),
         {:ok, segments, function, raw_args} <- call_ast(ast),
         {:ok, entry} <- allowlisted(segments, function, length(raw_args)),
         :ok <- Literal.validate_raw_option_keys(entry, raw_args),
         {:ok, args} <- Literal.convert(raw_args),
         :ok <- Literal.validate_arguments(entry, args),
         :ok <- remote_options(args, opts),
         scope when scope in [:read, :write, :deny] <- classify(entry.class, args),
         :ok <- allow_remote(scope),
         :ok <- max_scope(scope, Keyword.get(opts, :max_scope, :write)) do
      module = Module.concat(segments)
      {:ok, %{module: module, function: function, args: args, scope: scope}}
    else
      {:error, _} = error -> error
      {:unknown_atom, name} -> {:error, {:unknown_on_build, name}}
      {:unsupported, reason} -> {:error, reason}
      _ -> {:error, :non_literal_argument}
    end
  rescue
    _error -> {:error, :parse_error}
  end

  def parse(_expression, _opts), do: {:error, :parse_error}

  @spec run(map(), pos_integer(), binary()) :: {:ok, binary()} | {:error, :timeout}
  def run(%{module: module, function: function, args: args, scope: scope}, timeout_ms, actor)
      when is_atom(module) and is_atom(function) and is_list(args) and is_integer(timeout_ms) and timeout_ms >= 0 and is_binary(actor) do
    :ok = validate_run_call(module, function, args, scope)
    task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> execute(module, function, args, actor) end)
    task |> Task.yield(timeout_ms) |> run_result(task, scope)
  end

  @spec put_actor(binary()) :: binary()
  def put_actor(actor) when is_binary(actor), do: Process.put(@actor_key, actor)

  @spec actor() :: binary()
  def actor do
    Process.get(@actor_key, "local:" <> (System.get_env("USER") || "unknown"))
  end

  defp parse_ast(expression) do
    case Code.string_to_quoted(expression, existing_atoms_only: true, columns: true) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {_location, message, token}} ->
        detail = IO.iodata_to_binary([message, token])

        case Regex.run(~r/unsafe atom does not exist: ([^\s]+)/, detail) do
          [_, name] -> {:unknown_atom, name}
          _ -> {:error, :parse_error}
        end
    end
  end

  defp call_ast({{:., _, [{:__aliases__, _, segments}, function]}, _, args}) when is_atom(function) and is_list(args), do: {:ok, segments, function, args}
  defp call_ast(_ast), do: {:error, :not_allowlisted}

  defp allowlisted(segments, function, arity) do
    case Allowlist.fetch(segments, function, arity) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        if segments in allowed_modules(), do: {:error, {:unknown_on_build, Atom.to_string(function)}}, else: {:error, :not_allowlisted}
    end
  end

  defp allowed_modules do
    Allowlist.entries() |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  defp remote_options(args, opts) do
    if Keyword.get(opts, :remote, false) do
      forbidden = [:who, :actor, :set_by, :owner]
      has_identity? = Enum.any?(args, &contains_keys?(&1, forbidden))
      has_env? = Enum.any?(args, &contains_keys?(&1, [:env]))
      if has_identity? or has_env?, do: {:error, :option_not_allowed}, else: :ok
    else
      :ok
    end
  end

  defp contains_keys?(value, keys) when is_list(value) do
    (Keyword.keyword?(value) and Enum.any?(value, fn {key, nested} -> key in keys or contains_keys?(nested, keys) end)) or
      Enum.any?(value, &contains_keys?(&1, keys))
  end

  defp contains_keys?({_key, value}, keys), do: contains_keys?(value, keys)
  defp contains_keys?(_value, _keys), do: false

  defp classify(class, args) when is_function(class, 1), do: class.(args)
  defp classify(class, _args), do: class
  defp allow_remote(:deny), do: {:error, :denied_remote}
  defp allow_remote(_scope), do: :ok
  defp max_scope(:write, :read), do: {:error, :scope_exceeds_max}
  defp max_scope(_scope, scope) when scope in [:read, :write], do: :ok
  defp max_scope(_scope, _max), do: {:error, :scope_exceeds_max}

  defp validate_run_call(module, function, args, scope) do
    segments = Allowlist.entries() |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.find(&(Module.concat(&1) == module))
    validate_run_entry(segments, function, args, scope)
  end

  defp validate_run_entry(nil, _function, _args, _scope), do: unauthorized_call()

  defp validate_run_entry(segments, function, args, scope) do
    with {:ok, entry} <- Allowlist.fetch(segments, function, length(args)),
         :ok <- Literal.validate_arguments(entry, args),
         :ok <- remote_options(args, remote: true),
         true <- classify(entry.class, args) == scope and scope in [:read, :write] do
      :ok
    else
      _ -> unauthorized_call()
    end
  end

  defp unauthorized_call, do: raise(ArgumentError, "control call is not authorized by the allowlist")

  defp run_result({:ok, output}, _task, _scope), do: {:ok, output}
  defp run_result({:exit, _reason}, _task, _scope), do: {:ok, failure_output("control call task exited")}

  defp run_result(nil, task, scope) do
    if scope == :read, do: Task.shutdown(task, :brutal_kill), else: Task.ignore(task)
    {:error, :timeout}
  end

  defp execute(module, function, args, actor) do
    {:ok, io} = StringIO.open("")
    previous = Process.group_leader()
    Process.group_leader(self(), io)
    put_actor(actor)

    try do
      apply(module, function, args)
      {_input, output} = StringIO.contents(io)
      output
    rescue
      error -> finish_failure(io, Exception.message(error))
    catch
      kind, reason -> finish_failure(io, "#{kind}: #{inspect(reason)}")
    after
      Process.group_leader(self(), previous)
      StringIO.close(io)
    end
  end

  defp finish_failure(io, reason) do
    {_input, output} = StringIO.contents(io)
    output <> @error_marker <> one_line(reason) <> "\n" <> @exit_marker <> "1\n"
  end

  defp failure_output(reason), do: @error_marker <> reason <> "\n" <> @exit_marker <> "1\n"
  defp one_line(reason), do: reason |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)
end

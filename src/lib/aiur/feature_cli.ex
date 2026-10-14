defmodule Aiur.FeatureCLI do
  @moduledoc "Local feature commands shared by the launcher and daemon-bound tool."
  alias Aiur.BuildOrder.Features
  alias Aiur.FeatureCLI.{Arguments, Output, Writes}

  @spec run(keyword()) :: non_neg_integer()
  def run(opts) do
    args = Map.new(opts)

    case cli_context(args, opts) do
      {:ok, context} -> print(apply_op(args, context), args, opts)
      error -> print(error, args, opts)
    end
  end

  @spec apply_op(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:usage, String.t()}
  def apply_op(args, context) do
    with :ok <- Arguments.validate(args),
         {:ok, snapshot} <- Features.snapshot(Keyword.take(context, [:server, :timeout])) do
      if args.op == :show, do: Output.show(args, snapshot, context), else: Writes.apply(args, snapshot, context)
    end
  end

  defp cli_context(%{op: :show}, opts), do: {:ok, opts}

  defp cli_context(args, opts) do
    who = args[:who]

    if is_binary(who) and Regex.match?(~r/\A[A-Za-z0-9._-]{1,64}\z/, who) do
      actor = "cli:" <> who
      source = if args[:source] == "backfill-agent", do: "backfill-agent", else: actor
      {:ok, Keyword.merge(opts, actor: actor, source: source)}
    else
      {:usage, "write requires a valid --as or USER"}
    end
  end

  defp print({:ok, result}, args, _opts) do
    IO.puts(if args[:json], do: Jason.encode!(Aiur.JSONSafe.normalize(result)), else: Output.render(result))
    0
  end

  defp print({kind, reason}, args, opts) when kind in [:error, :usage] do
    message = if kind == :usage, do: reason, else: Output.error(reason)
    if args[:json], do: IO.puts(Jason.encode!(Aiur.JSONSafe.normalize(error_envelope(reason, message))))
    Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1)).("aiur: feature: " <> message)
    if kind == :usage, do: 64, else: 1
  end

  defp error_envelope(%{state: _} = health, _message), do: %{schema_version: 1, ok: false, health: health}
  defp error_envelope(_reason, message), do: %{schema_version: 1, ok: false, error: message}
end

defmodule Mix.Tasks.Aiur.Telemetry.Dashboard do
  use Mix.Task

  alias Aiur.RunTelemetry.Dashboard

  @shortdoc "Generate a self-contained Aiur telemetry dashboard"
  @requirements []

  @moduledoc """
  # Self-contained Aiur telemetry dashboard

  Generates the canonical offline analytics artifact from durable debug telemetry.

      mix aiur.telemetry.dashboard [INPUT ...]
      mix aiur.telemetry.dashboard --input log/telemetry.ndjson --output run.html
      mix aiur.telemetry.dashboard -i ~/.aiur/logs -i ./older-run --repo owner/repo

  Options:

    * `--input`, `-i` — telemetry file or directory; repeatable
    * `--output`, `-o` — output HTML path (default: `aiur-telemetry-dashboard.html`)
    * `--repo` — optional `owner/repo` used for best-effort GitHub enrichment
    * `--review-resume-grace-seconds` — wakeup grace window (default: 300)
    * `--help`, `-h` — print this help

  With no input, the task searches `~/.aiur/logs`. GitHub auth or network
  failures become warnings inside the report; local telemetry still renders.
  The task does not start Aiur application supervision.
  """

  @switches [
    input: :keep,
    output: :string,
    repo: :string,
    review_resume_grace_seconds: :integer,
    help: :boolean
  ]
  @aliases [i: :input, o: :output, h: :help]
  @default_output "aiur-telemetry-dashboard.html"
  @default_grace_seconds 300

  @impl Mix.Task
  def run(argv) do
    case parse_args(argv) do
      {:help, usage} ->
        Mix.shell().info(usage)

      {:error, message} ->
        Mix.raise(message)

      {:ok, parsed} ->
        options =
          [review_resume_grace_seconds: parsed.review_resume_grace_seconds]
          |> maybe_put(:repo, parsed.repo)

        case Dashboard.generate(parsed.inputs, parsed.output, options) do
          {:ok, result} ->
            Mix.shell().info("Wrote self-contained telemetry dashboard to #{result.output}")
            :ok

          {:error, {:no_telemetry_files, inputs}} ->
            Mix.raise("No telemetry files found in: #{Enum.join(inputs, ", ")}")

          {:error, reason} ->
            Mix.raise("Could not generate telemetry dashboard: #{format_reason(reason)}")
        end
    end
  end

  @doc false
  @spec parse_args([String.t()], keyword()) :: {:ok, map()} | {:help, String.t()} | {:error, String.t()}
  def parse_args(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      parsed[:help] ->
        {:help, @moduledoc}

      invalid != [] ->
        {:error, "Invalid option(s): #{format_invalid(invalid)}"}

      not valid_grace?(parsed[:review_resume_grace_seconds]) ->
        {:error, "--review-resume-grace-seconds must be a positive integer"}

      true ->
        caller_cwd = Keyword.get(opts, :caller_cwd, caller_cwd())

        inputs =
          case Keyword.get_values(parsed, :input) ++ positional do
            [] -> [Path.expand("~/.aiur/logs")]
            values -> Enum.map(values, &expand_path(&1, caller_cwd))
          end

        {:ok,
         %{
           inputs: inputs,
           output: expand_path(parsed[:output] || @default_output, caller_cwd),
           repo: normalize_repo(parsed[:repo]),
           review_resume_grace_seconds: parsed[:review_resume_grace_seconds] || @default_grace_seconds
         }}
    end
  end

  defp caller_cwd do
    System.get_env("AIUR_TELEMETRY_CALLER_CWD") || File.cwd!()
  end

  defp expand_path(path, caller_cwd) when is_binary(path), do: Path.expand(path, caller_cwd)

  defp valid_grace?(nil), do: true
  defp valid_grace?(value), do: is_integer(value) and value > 0

  defp normalize_repo(nil), do: nil

  defp normalize_repo(repo) do
    case String.trim(repo) do
      "" -> nil
      value -> value
    end
  end

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)

  defp format_invalid(invalid) do
    invalid
    |> Enum.map(fn {option, value} -> Enum.join(Enum.reject([option, value], &is_nil/1), "=") end)
    |> Enum.join(", ")
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason({reason, detail}) when is_atom(reason), do: "#{reason} (#{format_reason(detail)})"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(_reason), do: "unknown error"
end

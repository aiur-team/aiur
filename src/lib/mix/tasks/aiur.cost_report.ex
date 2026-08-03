defmodule Mix.Tasks.Aiur.CostReport do
  use Mix.Task

  alias Aiur.{Config, TrackerIdentity}
  alias Aiur.Usage.GroupedScopes
  alias Aiur.Usage.GroupedScopes.Scope
  alias Aiur.UsageAggregate.{Checkpoint, Projection}

  @shortdoc "Print spend by model, agent family, and ticket from the usage aggregate"
  @requirements []

  @moduledoc """
  # Spend by model, agent family, and ticket

  Pure wiring over `UsageAggregate` + `PriceTable` — needs no new recording. It
  reads the crash-safe aggregate projection checkpoint and re-prices the
  retained cells through the standard price table.

      mix aiur.cost_report
      mix aiur.cost_report --ticket 930
      mix aiur.cost_report --build analytics-optimizations
      mix aiur.cost_report --json

  Options:

    * `--ticket N` — scope to one ticket (repository-qualified).
    * `--build SLUG` — scope to the members of a build order (state node packs).
    * `--state-dir PATH` — override the usage-aggregate state directory.
    * `--json` — machine-readable JSON.
    * `--help`, `-h` — print this help.

  The default scope is the current daemon run. The task does not start Aiur
  application supervision; a missing or corrupt checkpoint is reported clearly
  rather than fabricated.
  """

  @switches [ticket: :string, build: :string, state_dir: :string, json: :boolean, help: :boolean]
  @aliases [h: :help]

  @impl Mix.Task
  def run(argv) do
    case parse_args(argv) do
      {:help, usage} ->
        Mix.shell().info(usage)

      {:error, message} ->
        Mix.raise(message)

      {:ok, parsed} ->
        case report(parsed) do
          {:ok, output} -> Mix.shell().info(output)
          {:error, reason} -> Mix.raise("cost-report: #{reason}")
        end
    end
  end

  @doc false
  @spec parse_args([String.t()], keyword()) :: {:ok, map()} | {:help, String.t()} | {:error, String.t()}
  def parse_args(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      invalid != [] ->
        {:error, "unknown options: #{Enum.map_join(invalid, ", ", &format_invalid/1)}"}

      positional != [] ->
        {:error, "unexpected arguments: #{Enum.join(positional, ", ")}"}

      parsed[:help] ->
        {:help, @moduledoc}

      true ->
        {:ok, parsed_options(parsed, opts)}
    end
  end

  defp parsed_options(parsed, opts) do
    %{
      ticket: parsed[:ticket],
      build: parsed[:build],
      state_dir: parsed[:state_dir] || Keyword.get(opts, :state_dir),
      json: parsed[:json] || false
    }
  end

  defp format_invalid({key, value}), do: "--#{key}=#{value}"
  defp format_invalid(key), do: "--#{key}"

  ## ---- report pipeline ----

  defp report(parsed) do
    with {:ok, projection} <- load_projection(parsed),
         {:ok, scope} <- resolve_scope(parsed) do
      source = %{cells: projection.cells, metadata: metadata(projection)}
      snapshot = GroupedScopes.project(source, scope, currency: "USD")
      {:ok, render(snapshot, parsed.json)}
    end
  end

  defp load_projection(parsed) do
    with {:ok, root} <- state_dir(parsed),
         checkpoint_path = Path.join(root, "checkpoint.json") do
      case Checkpoint.load(checkpoint_path) do
        {:ok, %Projection{} = projection} ->
          {:ok, projection}

        :missing ->
          {:error, "no usage aggregate checkpoint at #{checkpoint_path} — nothing recorded yet (or telemetry/ledger disabled)"}

        {:corrupt, reason} ->
          {:error, "usage aggregate checkpoint corrupt at #{checkpoint_path}: #{inspect(reason)}"}
      end
    end
  end

  defp state_dir(%{state_dir: dir}) when is_binary(dir) and dir != "", do: {:ok, dir}

  defp state_dir(_parsed) do
    case Config.Paths.usage_aggregate_state_dir() do
      {:ok, root} -> {:ok, root}
      {:error, reason} -> {:error, "could not resolve usage-aggregate state dir: #{inspect(reason)}"}
    end
  end

  defp metadata(%Projection{} = projection) do
    %{
      health: :healthy,
      freshness: %{status: :fresh},
      source_coverage: %{},
      generation: projection.generation,
      source_position: projection.source_position,
      source_generation: projection.source_generation
    }
  end

  defp resolve_scope(%{build: slug}) when is_binary(slug) and slug != "" do
    case build_identities(slug) do
      {:ok, identities} -> Scope.explicit_ticket_set(identities)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_scope(%{ticket: number}) when is_binary(number) and number != "" do
    with {:ok, identity} <- ticket_identity(number) do
      Scope.explicit_ticket_set([identity])
    end
  end

  defp resolve_scope(_parsed) do
    Scope.this_run(Aiur.Boot.run_id())
  end

  defp build_identities(slug) do
    node = Aiur.RunTelemetry.Summaries.state_node()

    case Aiur.RunTelemetry.Summaries.build_summary_path(slug) do
      _path ->
        # The build order pack itself (builds/<slug>/build-order.json) is
        # Executor-placed; the materialized build-summary carries the member
        # manifest when it exists.
        case read_build_members(node, slug) do
          {:ok, numbers} -> identities_from(numbers)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_build_members(node, slug) do
    candidates = [
      Path.join([node, "builds", slug, "build-order.json"]),
      Path.join([node, "builds", slug, "build-summary.json"])
    ]

    case Enum.find(candidates, &File.regular?/1) do
      nil ->
        {:error, "no build order or summary found for slug #{inspect(slug)} in state node #{node}"}

      path ->
        with {:ok, body} <- File.read(path),
             {:ok, decoded} <- Jason.decode(body) do
          members =
            Map.get(decoded, "tickets") || Map.get(decoded, "build_order", %{}) |> Map.get("members", [])

          numbers =
            Enum.flat_map(members, fn member ->
              case Map.get(member, "ticket") do
                n when is_integer(n) -> [to_string(n)]
                n when is_binary(n) -> [n]
                _other -> []
              end
            end)

          case numbers do
            [] -> {:error, "build order #{slug} has no ticket members"}
            numbers -> {:ok, numbers}
          end
        else
          {:error, reason} -> {:error, "could not read #{path}: #{inspect(reason)}"}
        end
    end
  end

  defp identities_from(numbers) do
    Enum.reduce_while(numbers, {:ok, []}, fn number, {:ok, acc} ->
      case ticket_identity(number) do
        {:ok, identity} -> {:cont, {:ok, [identity | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, identities} -> {:ok, Enum.reverse(identities)}
      error -> error
    end
  end

  @doc "Builds a joinable GitHub identity for one ticket number, or an error."
  @spec ticket_identity(String.t()) :: {:ok, TrackerIdentity.t()} | {:error, String.t()}
  def ticket_identity(number) do
    case Aiur.GitHub.Config.repo() do
      repo when is_binary(repo) and repo != "" ->
        case String.split(repo, "/", parts: 2) do
          [owner, name] when owner != "" and name != "" ->
            identity = %TrackerIdentity{
              status: :joinable,
              kind: :github,
              owner: owner,
              repository: name,
              provider_id: to_string(number),
              identifier: to_string(number),
              reason: nil
            }

            if TrackerIdentity.github_key(identity), do: {:ok, identity}, else: {:error, "unjoinable identity for ticket #{number}"}

          _other ->
            {:error, "could not derive owner/name from repo #{inspect(repo)}"}
        end

      _other ->
        {:error, "no configured repository for ticket-qualified scope"}
    end
  end

  ## ---- rendering ----

  defp render(snapshot, true), do: Jason.encode!(snapshot, pretty: true)

  defp render(snapshot, false) do
    scope = Map.get(snapshot, :scope, %{})

    lines = [
      "Cost report — scope: #{format_scope(scope)}",
      "Currency: #{Map.get(snapshot, :currency)}",
      "",
      "Spend by model:",
      ""
    ]

    lines = lines ++ model_lines(snapshot)
    lines = lines ++ ["", "Spend by agent family:", ""]
    lines = lines ++ agent_lines(snapshot)
    lines = lines ++ ["", "Spend by ticket:", ""]
    lines = lines ++ ticket_lines(snapshot)
    Enum.join(lines, "\n")
  end

  defp format_scope(%{kind: kind, run_id: run_id}) when is_binary(run_id),
    do: "#{kind} run #{run_id}"

  defp format_scope(%{kind: kind, ticket_count: count}), do: "#{kind} (#{count} ticket(s))"
  defp format_scope(_scope), do: "current run"

  defp model_lines(snapshot), do: dimension_lines(get_in(snapshot, [:contributors, :by_model]))
  defp agent_lines(snapshot), do: dimension_lines(get_in(snapshot, [:contributors, :by_agent_family]))
  defp ticket_lines(snapshot), do: dimension_lines(get_in(snapshot, [:contributors, :by_ticket]))

  defp dimension_lines(nil), do: ["  (none recorded)"]

  defp dimension_lines(entries) when is_list(entries) do
    case entries do
      [] -> ["  (none recorded)"]
      entries -> Enum.map(entries, &dimension_line/1)
    end
  end

  defp dimension_line(%{key: key, tokens: tokens, api_equivalent: api}) do
    amount = api |> Map.get(:amount, %{}) |> Map.get("USD")
    formatted = if amount, do: "$#{Decimal.round(amount, 2)}", else: "n/a"
    token_count = tokens |> Map.get("total", 0) || 0
    "  #{pad(key)} #{formatted}   (#{token_count} tokens)"
  end

  defp pad(key) when is_binary(key), do: String.pad_trailing(key, 24)
  defp pad(key), do: String.pad_trailing(to_string(key), 24)
end

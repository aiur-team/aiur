defmodule Aiur.CI.FailureDigest do
  @moduledoc """
  Failure evidence shared by CI consumers. `build/1` reads the configured repository.

  Check-level failures, unknown annotations and truncated reports are never flake-only.
  Signatures exclude known-flake tests and checks proven to contain only known flakes.
  Completed evidence is cached by SHA and check-run identity; open flake issues have a
  60-second classification window. This module does not rerun CI or change ticket state.
  """
  alias Aiur.GitHub.{FailureEvidence, PullRequests, ResourceStore, Transport}

  defstruct checks: [], tests: [], signature: nil, truncated: false, flake_only: false
  @type t :: %__MODULE__{checks: [map()], tests: [map()] | :unknown, signature: String.t(), truncated: boolean(), flake_only: boolean()}
  @failed ~w(failure timed_out cancelled action_required startup_failure stale)

  @spec build(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(sha, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, ci} <- PullRequests.fetch_commit_ci_status(sha, opts) do
      runs = ci.check_runs |> Enum.filter(&(&1["status"] == "completed" and &1["conclusion"] in @failed)) |> Enum.sort_by(& &1["id"])
      key = evidence_key(owner, repo, sha, ci)
      evidence = if runs == [], do: %{"annotations" => [], "known" => []}, else: evidence(key, runs, sha, opts)
      issues = if runs == [], do: {:ok, []}, else: FailureEvidence.flake_issues(opts)
      {:ok, digest(runs, ci.commit_status, evidence, issues)}
    end
  end

  defp evidence_key(owner, repo, sha, ci) do
    identities = ci.check_runs |> Enum.map(&Map.take(&1, ~w(id status conclusion))) |> Enum.sort()
    ResourceStore.key(:ci_failure_digest, owner, repo, sha <> ":" <> hash(identities))
  end

  defp evidence(key, runs, sha, opts) do
    case ResourceStore.fetch(key) do
      {:ok, %{data: data}} -> data
      :miss -> fetch_evidence(key, runs, sha, opts)
    end
  end

  defp fetch_evidence(key, runs, sha, opts) do
    annotations = Enum.map(runs, &read_annotations(&1, opts))
    known = FailureEvidence.known_flakes(sha, opts)
    data = %{"annotations" => annotations, "known" => if(match?({:ok, _}, known), do: elem(known, 1), else: nil)}
    if Enum.all?(annotations, &is_list/1) and match?({:ok, _}, known), do: ResourceStore.put_resource(key, data, source: :fetch)
    data
  end

  defp read_annotations(%{"id" => id}, opts) when is_integer(id) and id > 0 do
    case FailureEvidence.annotations(id, opts) do
      {:ok, annotations} -> annotations
      {:error, _} -> nil
    end
  end

  defp read_annotations(_, _), do: nil

  defp digest(runs, status, evidence, issues) do
    known = evidence["known"] || []

    issues =
      case issues do
        {:ok, bodies} -> bodies
        {:error, _} -> []
      end

    checks = Enum.zip_with(runs, evidence["annotations"], &check(&1, &2, known, issues)) ++ legacy_checks(status)
    tests = if Enum.any?(checks, &(&1.tests == :unknown)), do: :unknown, else: Enum.flat_map(checks, & &1.tests)
    signature_checks = checks |> Enum.reject(& &1.flake_only) |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()
    new_tests = checks |> Enum.flat_map(&new_tests/1) |> Enum.uniq() |> Enum.sort()

    %__MODULE__{
      checks: checks,
      tests: tests,
      signature: hash({signature_checks, new_tests}),
      truncated: Enum.any?(checks, & &1.truncated),
      flake_only: checks != [] and Enum.all?(checks, & &1.flake_only)
    }
  end

  defp check(run, annotations, known, issues) do
    parsed = if is_list(annotations), do: Enum.flat_map(annotations, &parse/1), else: []
    truncated = :truncated in parsed
    tests = parsed |> Enum.reject(&(&1 == :truncated)) |> Enum.map(&classify(&1, known, issues))
    unknown = is_nil(annotations) or :unknown in parsed
    tests = if unknown, do: :unknown, else: tests

    %{
      id: run["id"],
      name: run["name"],
      url: run["html_url"],
      tests: tests,
      truncated: truncated,
      flake_only: run["conclusion"] == "failure" and not unknown and not truncated and not other_failures?(annotations) and tests != [] and Enum.all?(tests, &(&1.classification == :known_flake))
    }
  end

  defp other_failures?(annotations), do: Enum.any?(annotations || [], &substantive_failure?/1)

  defp substantive_failure?(%{"annotation_level" => "failure", "message" => message} = annotation) do
    # The coverage wrapper repeats the exit status; timeout and unfamiliar errors still count.
    routine_exit = is_binary(message) and Regex.match?(~r/\Acoverage partition [1-4] failed with status 2; full log follows in the next step\z/, message)
    annotation["title"] != "aiur-test-failure" and not routine_exit
  end

  defp substantive_failure?(_), do: false

  defp parse(%{"title" => "aiur-test-failure", "message" => "truncated :: " <> _}), do: [:truncated]

  defp parse(%{"title" => "aiur-test-failure", "message" => message}) when is_binary(message) do
    case String.split(message, " :: ", parts: 3) do
      [class, module, name] when class in ~w(known-flake new-failure) and module != "" and name != "" -> [%{identity: module <> " :: " <> name}]
      _ -> [:unknown]
    end
  end

  defp parse(%{"title" => "aiur-test-failure"}), do: [:unknown]
  defp parse(_), do: []

  defp classify(:unknown, _, _), do: :unknown

  defp classify(test, known, issues) do
    known? = test.identity in known or Enum.any?(issues, &issue_names_test?(&1, test.identity))
    Map.put(test, :classification, if(known?, do: :known_flake, else: :new_failure))
  end

  defp issue_names_test?(issue, identity) do
    # Exact text, bounded by a line or Markdown code delimiter; never a partial test-name match.
    pattern = ~r/(?:^|[\r\n`])#{Regex.escape(identity)}(?:$|[\r\n`])/m
    Enum.any?([issue["title"], issue["body"]], &(is_binary(&1) and Regex.match?(pattern, &1)))
  end

  defp legacy_checks(status) do
    status
    |> Map.get("statuses", [])
    |> Enum.filter(&(&1["state"] in ~w(failure error)))
    |> Enum.map(&%{id: nil, name: &1["context"], url: &1["target_url"], tests: [], truncated: false, flake_only: false})
  end

  defp new_tests(%{tests: :unknown}), do: []
  defp new_tests(check), do: check.tests |> Enum.filter(&(&1.classification == :new_failure)) |> Enum.map(& &1.identity)
  defp hash(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
end

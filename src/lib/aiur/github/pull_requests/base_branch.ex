defmodule Aiur.GitHub.PullRequests.BaseBranch do
  @moduledoc """
  Verifies that a pull request targets the configured integration branch and
  repairs it when it does not. The repair is journaled before the PATCH.
  """

  require Logger

  alias Aiur.GitHub.{Errors, Transport, WriteThrough}

  @doc """
  Ensures an open pull request targets the configured integration branch.

  A matching pull request is read-only. A mismatch is repaired with GitHub's
  pull-request REST endpoint and accepted only when the response confirms the
  requested base, preserving every other pull-request field (including draft
  state). Failures retain the observed and expected branches for an actionable
  CI handoff.
  """
  @spec ensure_base_branch(map(), String.t(), keyword()) ::
          {:ok, :unchanged | {:repaired, String.t()}} | {:error, term()}
  def ensure_base_branch(pr, expected_base, opts \\ [])

  def ensure_base_branch(
        %{"number" => number, "base" => %{"ref" => current_base}},
        expected_base,
        opts
      )
      when is_binary(current_base) and is_binary(expected_base) and expected_base != "" do
    with {:ok, pr_number} <- positive_integer(number) do
      if current_base == expected_base do
        Logger.debug("Pull request base verified: pr=#{pr_number} base=#{inspect(expected_base)} action=unchanged")

        {:ok, :unchanged}
      else
        repair_base_branch(pr_number, current_base, expected_base, opts)
      end
    end
  end

  def ensure_base_branch(pr, expected_base, _opts)
      when not is_binary(expected_base) or expected_base == "" do
    {:error, {:invalid_pull_request_base_branch, expected_base, Map.get(pr, "number")}}
  end

  def ensure_base_branch(pr, expected_base, _opts) do
    {:error, {:pull_request_base_unavailable, %{pr_number: Map.get(pr, "number"), expected_base: expected_base}}}
  end

  defp repair_base_branch(pr_number, current_base, expected_base, opts) do
    Logger.warning(
      "Pull request base mismatch: pr=#{pr_number} current=#{inspect(current_base)} " <>
        "expected=#{inspect(expected_base)} action=repair"
    )

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         :ok <- journal_before_base_repair(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}"

      request_fun.(%{
        method: :patch,
        url: url,
        token: token,
        body: %{"base" => expected_base}
      })
      |> handle_base_repair_response(pr_number, current_base, expected_base)
    else
      {:error, {:base_repair_journal_failed, _reason} = reason} ->
        base_repair_error(pr_number, current_base, expected_base, reason, false)

      {:error, reason} ->
        base_repair_error(pr_number, current_base, expected_base, reason, false)
    end
  end

  defp journal_before_base_repair(opts) do
    case Keyword.fetch(opts, :before_base_repair_fun) do
      {:ok, journal_fun} when is_function(journal_fun, 0) ->
        try do
          case journal_fun.() do
            :ok -> :ok
            {:error, reason} -> {:error, {:base_repair_journal_failed, reason}}
            other -> {:error, {:base_repair_journal_failed, {:unexpected_result, other}}}
          end
        rescue
          error -> {:error, {:base_repair_journal_failed, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:base_repair_journal_failed, {kind, reason}}}
        end

      _ ->
        {:error, {:base_repair_journal_failed, :journal_callback_required}}
    end
  end

  defp handle_base_repair_response(
         {:ok,
          %{
            status: 200,
            body:
              %{
                "base" => %{"ref" => expected_base},
                "head" => %{"sha" => confirmed_head_sha}
              } = pull_request
          }},
         pr_number,
         _current_base,
         expected_base
       )
       when is_binary(confirmed_head_sha) and confirmed_head_sha != "" do
    Logger.info("Pull request base repaired: pr=#{pr_number} base=#{inspect(expected_base)} action=repaired")
    # The repair response is the whole pull request at its new `updated_at`.
    # Only the confirmed repair deposits: the not-confirmed clause below is a
    # state Aiur is refusing to believe, so caching it would be caching a doubt.
    WriteThrough.pull_request(pull_request)
    {:ok, {:repaired, confirmed_head_sha}}
  end

  defp handle_base_repair_response(
         {:ok, %{status: 200, body: body}},
         pr_number,
         current_base,
         expected_base
       ) do
    base_repair_error(
      pr_number,
      current_base,
      expected_base,
      {:repair_not_confirmed,
       %{
         base: get_in(body, ["base", "ref"]),
         head_sha: get_in(body, ["head", "sha"])
       }},
      true
    )
  end

  defp handle_base_repair_response(
         {:ok, %{status: _status} = response},
         pr_number,
         current_base,
         expected_base
       ) do
    base_repair_error(
      pr_number,
      current_base,
      expected_base,
      Errors.github_status_error(response),
      true
    )
  end

  defp handle_base_repair_response({:error, reason}, pr_number, current_base, expected_base) do
    base_repair_error(
      pr_number,
      current_base,
      expected_base,
      Errors.classify_error({:error, reason}),
      true
    )
  end

  defp base_repair_error(pr_number, current_base, expected_base, reason, repair_journaled) do
    {:error,
     {:pull_request_base_repair_failed,
      %{
        pr_number: pr_number,
        current_base: current_base,
        expected_base: expected_base,
        reason: reason,
        repair_journaled: repair_journaled
      }}}
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, {:invalid_pull_request_number, value}}
    end
  end

  defp positive_integer(value), do: {:error, {:invalid_pull_request_number, value}}
end

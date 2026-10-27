defmodule Aiur.LandingWatch.DisjointFailureCacheTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.DisjointFailureCache

  test "approved PR failure reads are computed once per poll" do
    observations = [approved(21), approved(22)]

    opts = [
      failed_checks_fun: fn observation, _ ->
        send(self(), {:checks, observation.number})
        {:ok, ["test"]}
      end,
      changed_paths_fun: fn number, _ ->
        send(self(), {:paths, number})
        {:ok, ["src/#{number}.ex"]}
      end
    ]

    assert :ok =
             DisjointFailureCache.run(observations, opts, fn observation, cached_opts ->
               if observation.number == 21 do
                 fetch = Keyword.fetch!(cached_opts, :disjoint_failure_prs_fun)
                 assert [%{pr: 21}, %{pr: 22}] = fetch.()
                 assert [%{pr: 21}, %{pr: 22}] = fetch.()
               end

               :ok
             end)

    assert_received {:checks, 21}
    assert_received {:checks, 22}
    assert_received {:paths, 21}
    assert_received {:paths, 22}
    refute_received {:checks, _}
    refute_received {:paths, _}
  end

  defp approved(number) do
    head = "head-#{number}"

    %{
      number: number,
      head: head,
      raw: %{
        "reviewDecision" => "APPROVED",
        "headRefOid" => head,
        "reviews" => %{"nodes" => [%{"commit" => %{"oid" => head}}]}
      }
    }
  end
end

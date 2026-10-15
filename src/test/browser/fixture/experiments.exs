defmodule Aiur.BrowserHarness.ExperimentsFixture do
  @moduledoc false
  import Plug.Conn
  alias Aiur.Experiments.Spec
  alias Aiur.RepoBase

  @fixtures Path.expand("../../aiur/experiments/fixtures", __DIR__)
  @root Path.join(System.tmp_dir!(), "browser-experiments-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}")

  def init(opts), do: opts
  def call(conn, _opts), do: configure(conn, conn.params)

  def configure(conn, %{"scenario" => scenario}) when scenario in ~w(empty mixed custom-pack) do
    prepare(scenario)
    Phoenix.PubSub.broadcast(Aiur.PubSub, "experiments", {:experiments_changed, :all})
    conn |> put_resp_header("location", "/experiments") |> send_resp(302, "")
  end

  def configure(conn, _params), do: send_resp(conn, 400, "Unknown experiments fixture scenario")

  def prepare(scenario) do
    Application.put_env(:aiur, :repo_base_root, Path.join(@root, "repo-state"))
    root = Path.join(@root, scenario)
    File.mkdir_p!(root)

    if scenario == "mixed" do
      write_spec(root, "valid_line", "release-speed", "Release delivery speed", "2026-10-09T00:00:00Z", "delivery-speed/start_to_merge")
      File.cp!(Path.join(@fixtures, "results/page_analysis.json"), Path.join([root, "release-speed", "result.json"]))
      write_spec(root, "valid_ab", "cohort-speed", "Cohort delivery speed", "2026-10-08T00:00:00Z", "delivery-speed/start_to_merge")
    end

    if scenario == "custom-pack" do
      packs = Path.join(RepoBase.base_path("test-org/test-repo"), ".aiur/experiments/packs")
      File.mkdir_p!(packs)
      File.cp!(Path.expand("../../fixtures/experiments/consumer_repo/.aiur/experiments/packs/app.json", __DIR__), Path.join(packs, "app.json"))
      write_spec(root, "valid_line", "custom-latency", "Application latency", "2026-10-09T00:00:00Z", "app/request_latency")
    end

    Application.put_env(:aiur, :experiments_dir, root)
  end

  defp write_spec(root, fixture, id, title, created_at, metric_ref) do
    spec =
      Path.join(@fixtures, fixture <> ".json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("spec")
      |> Map.merge(%{"id" => id, "title" => title, "min_samples" => 10, "created_at" => created_at, "metrics" => [%{"ref" => metric_ref, "direction" => "decrease", "primary" => true}]})

    {:ok, validated} = Spec.new(spec)
    directory = Path.join(root, id)
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "spec.json"), Jason.encode!(Spec.to_map(validated)))
    File.write!(Path.join(directory, "journal.ndjson"), "")
    File.write!(Path.join(directory, "annotations.ndjson"), "")
  end
end

defmodule Aiur.BrowserHarness.ExperimentsFixture do
  @moduledoc false
  import Plug.Conn
  alias Aiur.Experiments.{Evidence, Spec}
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
      write_charts(root)
      write_report(root)
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

  defp write_report(root) do
    report = Path.expand("../../fixtures/experiments/report.valid.json", __DIR__) |> File.read!() |> Jason.decode!()
    report = report |> put_in(["header", "experiment_id"], "release-speed") |> put_in(["header", "generated_at"], "2026-10-09T00:00:00Z")
    directory = Path.join([root, "release-speed", "report"])
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "contract.json"), Jason.encode!(%{"first_results_read_at" => nil, "preregistration" => nil, "reports" => [report]}))
  end

  defp write_charts(root) do
    detail = @fixtures |> Path.join("chart_detail.json") |> File.read!() |> Jason.decode!()
    directory = Path.join(root, "release-speed")
    spec = Map.merge(detail["spec"], %{"id" => "release-speed", "title" => "Release delivery speed"})
    File.write!(Path.join(directory, "spec.json"), Jason.encode!(spec))
    body = Map.put(detail["analysis"], "experiment_id", "release-speed")
    File.write!(Path.join(directory, "result.json"), Jason.encode!(%{"body" => body}))
    snapshots = Path.join(directory, "snapshots")
    File.mkdir_p!(snapshots)

    entries =
      Enum.map(detail["snapshots"], fn snapshot ->
        snapshot = snapshot |> Map.put("computed_at", "2026-10-10T00:00:00Z") |> Map.put("experiment_id", "release-speed") |> Map.put("sha256", nil) |> Map.delete("sha256")
        snapshot = Map.put(snapshot, "sha256", Evidence.hash(snapshot))
        File.write!(Path.join(snapshots, "#{snapshot["window_name"]}.r1.json"), Jason.encode!(snapshot))
        Jason.encode!(%{"schema_version" => 1, "kind" => "frozen", "window" => snapshot["window_name"], "revision" => 1, "sha256" => snapshot["sha256"]})
      end)

    File.write!(Path.join(directory, "journal.ndjson"), Enum.join(entries, "\n") <> "\n")
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

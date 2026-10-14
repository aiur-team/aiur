defmodule Aiur.BrowserHarness.OptimisticControl do
  use Phoenix.Controller, formats: [:html]

  def configure(conn, %{"mode" => mode}) when mode in ["started", "absent"] do
    fixture = Path.expand("../../../../analytics/tests/fixtures/optimistic/telemetry.ndjson", __DIR__)
    path = Path.join(System.tmp_dir!(), "optimistic-browser-#{System.unique_integer([:positive])}.ndjson")

    records =
      fixture
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(fn line -> mode == "started" or Jason.decode!(line)["attributes"]["event"] == "dispatch" end)

    File.write!(path, Enum.join(records, "\n") <> "\n")
    Application.put_env(:aiur, :analytics_telemetry_file, path)
    text(conn, "configured #{mode}")
  end
end

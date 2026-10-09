defmodule Aiur.CI.FailureDigestAnnotationProbeTest do
  use ExUnit.Case, async: true

  test "annotation transport :: 100%" do
    flunk("Temporary MP0 CI annotation transport probe; removed after dispatch")
  end
end

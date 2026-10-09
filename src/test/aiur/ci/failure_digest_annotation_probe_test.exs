defmodule Aiur.CI.FailureDigestAnnotationProbeTest do
  use ExUnit.Case

  test "annotation transport :: 100%" do
    flunk("intentional CI annotation transport probe")
  end
end

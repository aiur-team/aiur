defmodule Aiur.TestSupport.BuildGateFixtures do
  @moduledoc false

  def write_fake_mix!(path) do
    File.write!(path, """
    #!/usr/bin/env bash

    if [[ ${FAKE_MIX_IGNORE_TERM:-0} == 1 ]]; then
      trap '' TERM
    fi

    update_concurrency() {
      [[ -n ${FAKE_MIX_CONCURRENCY:-} ]] || return 0

      exec 8>>"${FAKE_MIX_CONCURRENCY}.lock"
      flock 8
      active=$(cat "$FAKE_MIX_CONCURRENCY")
      active=$((active + $1))
      printf '%s\n' "$active" > "$FAKE_MIX_CONCURRENCY"

      max=$(cat "$FAKE_MIX_MAX_CONCURRENCY")
      if ((active > max)); then
        printf '%s\n' "$active" > "$FAKE_MIX_MAX_CONCURRENCY"
      fi

      flock -u 8
      exec 8>&-
    }

    printf '%s\\n' "$*" >> "$FAKE_MIX_LOG"
    if [[ -n ${FAKE_MIX_PID:-} ]]; then
      printf '%s\\n' "$$" > "$FAKE_MIX_PID"
    fi
    if [[ ${FAKE_MIX_ATTACK_LOCKS:-0} == 1 ]]; then
      rm -f "$AIUR_BUILD_GATE_LOCK_DIR/slot-1.lock" && exit 90
      printf replaced > "$AIUR_BUILD_GATE_LOCK_DIR/slot-1.lock" && exit 91
    fi
    update_concurrency 1
    if [[ -n ${FAKE_MIX_TIMING_LOG:-} ]]; then
      printf 'start %s %s\\n' "$1" "$(date +%s)" >> "$FAKE_MIX_TIMING_LOG"
    fi
    if [[ -n ${FAKE_MIX_STARTED:-} ]]; then
      : > "$FAKE_MIX_STARTED"
    fi

    if [[ -n ${FAKE_MIX_ADOPTED_DAEMON_PID:-} ]]; then
      # A daemon from an unrelated session, the way dbus-daemon and
      # gnome-keyring-daemon appear under a build. It leaves this command's
      # session, ignores TERM, and outlives mix. The intermediate `( ... )`
      # subshell exits immediately so the daemon reparents onto the holder's
      # subreaper even while the command is still running -- the #2387
      # incident shape.
      (
        setsid bash -c '
          trap "" TERM
          printf "%s\\n" "$$" > "$1"
          if [[ ${FAKE_MIX_ADOPTED_DAEMON_WAKEUP:-0} == 1 ]]; then
            # A real session daemon is not `sleep`: it wakes on timers and
            # handles messages, consuming a small but nonzero slice of CPU.
            # This low-duty-cycle timer loop (a ~0.5ms burst every second) is
            # that shape, staying far below the 3ms/s busy threshold, so the
            # threshold lower bound is pinned by a test rather than by
            # assertion (#2398).
            while :; do
              for ((i = 0; i < 300; i++)); do :; done
              sleep 1
            done
          else
            exec sleep 600
          fi
        ' fake-adopted-daemon "$FAKE_MIX_ADOPTED_DAEMON_PID" </dev/null >/dev/null 2>&1 &
      ) </dev/null >/dev/null 2>&1
    fi

    if [[ -n ${FAKE_MIX_ADOPTED_DAEMON_DEFAULT_TERM_PID:-} ]]; then
      # The real gnome-keyring-daemon does not ignore SIGTERM, so the
      # TERM-ignoring daemon above is more robust than production: a partial
      # revert of #2391 that sweeps adopted daemons with SIGTERM alone would
      # kill this default-disposition daemon while the ignoring one survived,
      # and the keyring-protection test would still look green. Both must
      # survive containment (#2404).
      (
        setsid bash -c '
          printf "%s\n" "$$" > "$1"
          exec sleep 600
        ' fake-adopted-daemon-default-term "$FAKE_MIX_ADOPTED_DAEMON_DEFAULT_TERM_PID" </dev/null >/dev/null 2>&1 &
      ) </dev/null >/dev/null 2>&1
    fi

    if [[ -n ${FAKE_MIX_DESCENDANT_RELEASE:-} ]] || ((FAKE_MIX_DESCENDANT_SLEEP > 0)); then
      (
        printf '%s\\n' "$$" > "${FAKE_MIX_DESCENDANT}.pid"
        printf 'started\\n' > "$FAKE_MIX_DESCENDANT"
        if [[ -n ${FAKE_MIX_DESCENDANT_RELEASE:-} ]]; then
          # A real duty cycle, not a bare polling loop: a short busy spin per
          # wakeup keeps this "CPU-burning" descendant unambiguously above the
          # holder's 3ms/s idle threshold even when the host is loaded. A bare
          # `sleep 0.02` poll drifts to ~5-7ms/s — only ~2x the threshold —
          # and drops under it under CI load, releasing the retained slot
          # early (#2398).
          while [[ ! -e $FAKE_MIX_DESCENDANT_RELEASE ]]; do
            for ((i = 0; i < 500; i++)); do :; done
            sleep 0.02
          done
        else
          sleep "$FAKE_MIX_DESCENDANT_SLEEP"
        fi
        if [[ -n ${FAKE_MIX_DESCENDANT_COMMAND:-} ]]; then
          FAKE_MIX_DESCENDANT_RELEASE= FAKE_MIX_DESCENDANT_COMMAND= \
            bash -c "$FAKE_MIX_DESCENDANT_COMMAND" > "$FAKE_MIX_DESCENDANT_GATE_LOG" 2>&1
        fi
        printf 'done\\n' > "${FAKE_MIX_DESCENDANT}.done"
      ) </dev/null >/dev/null 2>&1 &
      update_concurrency -1
      exit 0
    fi

    sleep "${FAKE_MIX_SLEEP:-0}"
    if [[ -n ${FAKE_MIX_TIMING_LOG:-} ]]; then
      printf 'end %s %s\\n' "$1" "$(date +%s)" >> "$FAKE_MIX_TIMING_LOG"
    fi
    update_concurrency -1
    exit "${FAKE_MIX_EXIT_STATUS:-0}"
    """)

    File.chmod!(path, 0o755)
  end

  def write_fake_elixir_mix!(path) do
    File.write!(path, """
    #!/usr/bin/env elixir
    File.write!(System.fetch_env!("FAKE_MIX_LOG"), Enum.join(System.argv(), " ") <> "\\n", [:append])
    """)

    File.chmod!(path, 0o755)
  end

  def write_controlled_mv!(path, real_mv) do
    File.write!(path, """
    #!/usr/bin/env bash
    destination=${!#}

    if [[ $destination == */slot-1.owner ]]; then
      exec 8>>"$AIUR_TEST_MV_COUNT.lock"
      flock 8
      count=$(cat "$AIUR_TEST_MV_COUNT" 2>/dev/null || printf '0')
      count=$((count + 1))
      printf '%s\n' "$count" > "$AIUR_TEST_MV_COUNT"
      flock -u 8
      exec 8>&-

      if [[ ${AIUR_TEST_FAIL_FINAL_OWNER_MV:-0} == 1 ]] && ((count == 3)); then
        exit 88
      fi
    fi

    "#{real_mv}" "$@"
    status=$?

    if ((status == 0)) && [[ ${AIUR_TEST_DELAY_OWNER_MV:-0} == 1 ]] &&
      [[ $destination == */slot-1.owner ]]; then
      sleep 0.2
    fi

    exit "$status"
    """)

    File.chmod!(path, 0o755)
  end

  def write_controlled_mktemp!(path, real_mktemp) do
    File.write!(path, """
    #!/usr/bin/env bash
    created=$("#{real_mktemp}" "$@") || exit $?

    if [[ -n ${AIUR_TEST_HANDSHAKE_FIFO_FRAGMENT:-} ]] &&
      [[ $created == *"$AIUR_TEST_HANDSHAKE_FIFO_FRAGMENT"* ]]; then
      rm -f "$created" || exit $?
      mkfifo "$created" || exit $?
    fi

    printf '%s\\n' "$created"
    """)

    File.chmod!(path, 0o755)
  end

  def write_fake_mise!(path) do
    File.write!(path, """
    #!/usr/bin/env bash
    if [[ $1 == which ]]; then
      target="${FAKE_MISE_WHICH_DIR:-}/$2"
      [[ -n ${FAKE_MISE_WHICH_DIR:-} && -x $target ]] || exit 1
      printf '%s\\n' "$target"
      exit 0
    fi
    if [[ $1 =~ ^(exec|x)$ ]]; then
      shift
      while (($#)); do
        case $1 in
          --)
            shift
            exec "$@"
            ;;
          -c|--command)
            shift
            exec bash -c "$1"
            ;;
          --command=*)
            exec bash -c "${1#--command=}"
            ;;
          *) shift ;;
        esac
      done
    fi
    exit 64
    """)

    File.chmod!(path, 0o755)
  end

  def write_real_mix_project!(path) do
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule LeaseProbe.MixProject do
      use Mix.Project

      def project, do: [app: :lease_probe, version: "0.1.0", elixir: "~> 1.15"]
    end
    """)

    File.write!(Path.join(path, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(path, "test/lease_probe_test.exs"), ~S'''
    defmodule LeaseProbeTest do
      use ExUnit.Case

      test "leaves a detached OS child alive" do
        script = ~S"""
        printf started > "$LEASE_DESCENDANT_STARTED"
        while [ ! -e "$LEASE_DESCENDANT_RELEASE" ]; do sleep 0.02; done
        printf done > "$LEASE_DESCENDANT_DONE"
        """

        {_, 0} =
          System.cmd(
            "sh",
            ["-c", ~S|sh -c "$1" </dev/null >/dev/null 2>&1 &|, "lease-probe", script]
          )
      end
    end
    ''')
  end
end

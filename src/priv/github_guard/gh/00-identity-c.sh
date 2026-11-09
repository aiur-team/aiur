# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
      fi

      if [ -z "$budget_token" ]; then
        budget_unavailable_reason='GitHub credential is unavailable'
      else
        budget_key=$(fingerprint_value "$budget_token") || budget_key=
        [ -n "$budget_key" ] || budget_unavailable_reason='credential fingerprint is unavailable'
        budget_key_derived=1
      fi
      unset budget_token
    fi

    if [ -z "$budget_unavailable_reason" ]; then
      budget_db=$budget_root/budget.sqlite3
      budget_enabled=1
    fi
  fi
fi

if [ "$budget_enabled" -eq 1 ]; then
  budget_consumer_key=$(fingerprint_value "$budget_consumer") || budget_consumer_key=
  [ -n "$budget_consumer_key" ] || budget_consumer_key=shared
fi
# The raw identity is the human-readable actor label for the usage report; the
# consumer key above stays a fingerprint. Preserved separately so `usage` can
# name this caller even when AIUR_GITHUB_BUDGET_CONSUMER is not exported.
budget_consumer_label=${AIUR_GITHUB_BUDGET_CONSUMER:-"executor:${PPID:-$$}"}
unset budget_consumer


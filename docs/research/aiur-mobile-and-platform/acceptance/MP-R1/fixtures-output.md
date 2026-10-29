# MP-R1 fixtures output

Commands target main `889212aa39a2fb992da7942c6e4236f7b70be376`.
Local checkout prefixes are rendered as `<isolated-main>` or `<workspace>`;
ANSI color codes and blank output lines are removed. Result lines are otherwise unchanged.

## 03-checker-fixtures

Working directory: `.`.

Command:

```sh
bash scripts/test-check-components.sh --with-node --with-elixir
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:25.852223Z
UTC end: 2026-10-26T11:41:09.519379Z
Exit code: 0
PASS: component_debt_reports_both_directions
PASS: owned_once_passes
PASS: unowned_file_fails
PASS: ambiguous_owner_fails
PASS: more_specific_glob_wins
PASS: stale_glob_fails
PASS: schema_violation_exits_2
PASS: facade_star_requires_pending
PASS: facade_star_with_pending_passes
PASS: single_star_stays_in_segment
PASS: double_star_matches_zero_depth
PASS: same_component_overlap_passes
PASS: fallback_excludes_build_outputs
PASS: git_uses_tracked_files
PASS: outside_roots_can_have_paths
PASS: format_is_deterministic
PASS: unknown_component_key_fails
PASS: unknown_root_key_fails
PASS: unknown_dependency_fails
PASS: duplicate_component_fails
PASS: relative_paths_required
PASS: public_kind_required
PASS: boolean_layer_rejected
PASS: private_namespaces_supported
PASS: future_public_fields_supported
PASS: required_property_fails
PASS: empty_name_fails
PASS: duplicate_paths_fail
PASS: public_features_format_passes
PASS: missing_public_field_fails
PASS: planned_with_paths_fails
PASS: planned_without_added_by_fails
PASS: feature_adds_non_planned_fails
PASS: planned_feature_component_unlisted_fails
PASS: planned_feature_wrong_owner_fails
PASS: planned_bucket1_component_exempt_passes
PASS: planned_bucket1_unlisted_passes
PASS: summary_with_module_name_fails
PASS: summary_with_path_fails
PASS: summary_with_issue_fails
PASS: summary_with_secret_fails
PASS: summary_with_ip_fails
PASS: summary_with_hostname_fails
PASS: summary_with_url_fails
PASS: name_with_module_fails
PASS: summary_too_long_fails
PASS: summary_trailing_space_fails
PASS: summary_multiple_sentences_fails
PASS: summary_without_sentence_fails
PASS: summary_newline_fails
PASS: summary_final_newline_fails
PASS: name_final_newline_fails
PASS: summary_uppercase_secret_fails
PASS: env_value_fails
PASS: env_final_newline_fails
PASS: env_names_and_wildcard_pass
PASS: feature_bucket1_id_fails
PASS: feature_duplicate_id_fails
PASS: feature_unknown_component_fails
PASS: feature_empty_union_fails
PASS: feature_private_copy_still_validated
PASS: feature_public_flag_boolean_fails
PASS: feature_unknown_key_fails
PASS: feature_release_tag_passes
PASS: feature_empty_release_fails
PASS: features_required_fails
PASS: status_core_passes
PASS: status_optional_passes
PASS: status_experimental_passes
PASS: status_deprecated_passes
PASS: invalid_status_fails
PASS: invalid_dependency_kind_fails
PASS: install_included_passes
PASS: install_npm_passes
PASS: install_setup_passes
PASS: install_missing_package_fails
PASS: install_extra_fails
PASS: install_unknown_fails
PASS: install_setup_path_fails
PASS: docs_absolute_fails
PASS: docs_traversal_fails
PASS: docs_suffix_fails
PASS: capability_value_fails
PASS: config_path_fails
PASS: install_secret_name_fails
PASS: docs_secret_name_fails
PASS: release_url_fails
PASS: nested_config_override_passes
PASS: nested_config_unknown_field_fails
PASS: nested_config_unknown_section_fails
PASS: nested_config_duplicate_override_fails
PASS: nested_config_malformed_path_fails
PASS: nested_config_override_requires_root_owner
PASS: relative_inside_package_passes
PASS: import_into_src_fails
PASS: sibling_package_fails
PASS: undeclared_npm_dep_fails
PASS: computed_import_fails
PASS: computed_require_fails
PASS: comment_mention_ignored
PASS: contracts_import_allowed
PASS: contracts_must_be_declared
PASS: declared_npm_and_builtins_pass
PASS: bare_prefix_only_builtin_fails
PASS: unknown_node_builtin_fails
PASS: export_into_src_fails
PASS: import_equals_into_src_fails
PASS: import_type_into_src_fails
PASS: literal_dynamic_into_src_fails
PASS: literal_require_into_src_fails
PASS: test_outside_src_fails
PASS: symlinked_npm_into_src_fails
PASS: relative_symlink_into_src_fails
PASS: non_js_package_dir_without_package_json_passes
PASS: missing_package_json_exits_2
PASS: external_resource_into_packages_reported
PASS: external_resource_attribute_reported
PASS: multiline_external_resource_reported
PASS: multiline_resource_attribute_reported
PASS: file_dependency_into_sibling_fails
PASS: link_dependency_into_sibling_fails
PASS: file_dependency_into_src_fails
PASS: file_dependency_contracts_allowed
PASS: parenthesized_external_resource_reported
PASS: resource_alias_chain_reported
PASS: streamdeck_external_resource_into_package_rejected
PASS: streamdeck_external_resource_into_other_package_rejected
PASS: declarations_owned_once_passes
PASS: tracker_without_owner_fails
PASS: tracker_owned_twice_fails
PASS: tracker_stale_owner_fails
PASS: debug_without_owner_fails
PASS: debug_owned_twice_fails
PASS: debug_stale_owner_fails
PASS: AIUR_FIXTURE_without_owner_fails
PASS: AIUR_FIXTURE_owned_twice_fails
PASS: AIUR_FIXTURE_stale_owner_fails
PASS: fixture_dir_without_owner_fails
PASS: fixture_dir_owned_twice_fails
PASS: fixture_dir_stale_owner_fails
PASS: zero_config_matches_is_broken_matcher
PASS: zero_env_matches_is_broken_matcher
PASS: zero_state_matches_is_broken_matcher
PASS: new_section_without_owner_fails
PASS: new_env_without_owner_fails
PASS: repo_state_path_owned_passes
PASS: repo_state_path_without_owner_fails
PASS: unknown_shared_component_fails
PASS: invalid_config_format_fails
PASS: invalid_env_format_fails
PASS: invalid_state_format_fails
PASS: real_tree_passes
PASS: malformed_json_exits_2
PASS: missing_typescript_exits_2
PASS: experiments_forbid_orchestrator
PASS: undeclared_dependency_fails
PASS: GitHub access ownership (191 Elixir files; 24 wrapper parts)
PASS: access_to_domain_fails
PASS: access_to_domain_declared_passes
PASS: access_domain_doc_mentions_ignored
PASS: declared_facade_passes
PASS: component_route_kit_passes
PASS: component_route_shell_fails
PASS: harness_private_namespace_violation
PASS: harness_private_Claude
PASS: harness_private_Muse
PASS: harness_private_OpenAICompat
PASS: harness_comment_mention_ok
PASS: harness_neutral_contracts_ok
PASS: harness_allowlisted_alias_ok
PASS: harness_stale_exception_fails
PASS: harness_literal_violation
PASS: harness_explicit_facade_ok
PASS: event_bus_private_module_fails
PASS: event_bus_upward_reference_fails
PASS: event_bus_kernel_config_pass
PASS: event_bus_live_ratchet_passes
PASS: event_bus_stale_ratchet_fails
PASS: event_bus_new_member_requires_ownership
PASS: private_module_fails
PASS: facade_star_allows_any
PASS: alias_resolution_counts
PASS: doc_mentions_ignored
PASS: allowlisted_violation_passes
PASS: new_violation_beside_allowlist_fails
PASS: composition_root_exempt
PASS: alias_as_resolves
PASS: alias_scope_does_not_leak
PASS: import_reference_counts
PASS: use_reference_counts
PASS: behaviour_reference_counts
PASS: type_reference_counts
PASS: parse_failure_exits_2
PASS: unresolved_internal_is_warning
PASS: optional_facade_passes
PASS: facade_is_exact
PASS: primary_source_module
PASS: baseline_overwrite_refused
PASS: malformed_allowlist_exits_2
PASS: baseline_generation_and_recheck
PASS: untracked_parse_error_ignored
PASS: nested_namespace_resolves
PASS: absolute_nested_module_resolves
PASS: application_primary_module
PASS: upward_reference_fails
PASS: same_layer_passes
PASS: downward_reference_passes
PASS: required_to_optional_fails
PASS: composition_root_may_reference_optional
PASS: optional_to_required_passes
PASS: optional_to_optional_passes
PASS: scc_reported_not_failed
PASS: acyclic_components_separate
PASS: allowlisted_cycle_includes_root
PASS: rules_allowlisted_separately
PASS: selective_baseline_appends_and_refuses_repeat
PASS: selected_rule_does_not_mask_default_gate
PASS: unknown_rule_exits_2
PASS: iterative_tarjan_deep_graph
PASS: missing_elixir_exits_2
PASS: docs_tree_without_sources_passes
PASS: docs_schema_invalid_fails
PASS: directory_published_required_fails
PASS: docs_path_missing_fails
PASS: docs_anchor_missing_fails
PASS: docs_anchor_slug_passes
PASS: docs_fenced_anchor_fails
PASS: docs_custom_and_duplicate_anchors_pass
PASS: docs_invalid_fence_closer_fails
PASS: docs_commented_anchor_fails
PASS: docs_entity_anchor_passes
PASS: docs_raw_entity_anchor_fails
PASS: setup_docs_missing_fails
PASS: config_heading_missing_fails
PASS: config_heading_exact_match_fails
PASS: config_fenced_heading_fails
PASS: env_unknown_fails
PASS: env_prefix_unknown_fails
PASS: env_empty_schema_exits_2
PASS: capability_unknown_fails
PASS: capability_template_id_passes
PASS: capability_template_bare_fails
PASS: capability_template_nested_fails
PASS: capability_template_uppercase_fails
PASS: capability_enum_missing_exits_2
PASS: sidebar_missing_when_published_fails
PASS: sidebar_present_when_published_passes
PASS: sidebar_not_required_when_unpublished
PASS: dangling_component_ref_fails
PASS: dangling_optional_ref_fails
PASS: dangling_feature_ref_fails
PASS: missing_manifest_exits_2
PASS: docs_invalid_json_exits_2
PASS: full_checker_checks_docs
PASS: ci_docs_only_step_rejects_broken_link
PASS: split_manifest_docs_passes
PASS: independent seam additions merge without conflict
PASS: valid state file pattern
PASS: stale state file pattern
PASS: malformed state file pattern
PASS: trailing newline is rejected
PASS: duplicate state file pattern
PASS: sanctioned_lifecycle_writer_passes
PASS: sanctioned_lifecycle_alias_passes
PASS: lifecycle_exception_other_path_fails
PASS: lifecycle_exception_child_module_fails
PASS: ordinary_seam_cannot_override_forbid
PASS: hints_seam_passes
PASS: claim_probe_behaviour_seam
PASS: claim_probe_types_pass_in_implementation
PASS: claim_probe_reference_elsewhere_fails
PASS: other_build_queue_module_from_orchestration_fails
PASS: seam_kind_is_exact
PASS: forbidden_orchestrator_ref_fails
PASS: forbidden_github_ref_fails
PASS: forbidden_grouped_alias_fails
PASS: forbidden_literal_module_fails
PASS: forbidden_module_atom_fails
PASS: future_guard_comments_and_docs_ignored
PASS: similar_namespace_allowed
PASS: event_bus_alias_public_upward_fails
PASS: event_bus_alias_private_upward_fails
PASS: event_bus_grouped_alias_public_upward_fails
PASS: event_bus_grouped_alias_private_upward_fails
PASS: event_bus_kernel_alias_passes
PASS: event_bus_pubsub_alias_forbidden
PASS: event_bus_kernel_alias_forbidden
PASS: event_bus_config_alias_forbidden
PASS: event_bus_boundary_literal_forbidden
PASS: event_bus_boundary_qualified_call_forbidden
PASS: event_bus_alias_nonmember_bus_module_forbidden
PASS: event_bus_nonmember_pubsub_call_passes
PASS: file_level_alias_is_forbidden
PASS: listener_reverse_direction_fails
PASS: build_order_only_in_source_module_1
PASS: build_order_only_in_source_module_0
PASS: build_order_unused_alias_also_restricted
PASS: seam_does_not_suppress_private
PASS: seam_does_not_suppress_upward
PASS: unknown_seam_component_rejected
PASS: unsafe_seam_path_rejected
PASS: unknown_port_component_rejected
PASS: seam_lookup_is_order_independent
component seam guard: all cases passed
PASS: independent_scanner_passes
PASS: scanner_cannot_reference_orchestration
PASS: orchestration_cannot_reference_scanner
PASS: GitHub facade Aiur.GitHub.Client -> 0
PASS: GitHub facade Aiur.GitHub.Access -> 0
PASS: GitHub facade Aiur.GitHub.Access.Settings -> 0
PASS: GitHub facade Aiur.GitHub.ResourceStore -> 1
PASS: GitHub facade Aiur.GitHub.ResourceStore -> 0
PASS: GitHub facade Aiur.GitHub.ResourceStore.Memory -> 1
PASS: GitHub facade Aiur.GitHub.RequestLog -> 1
...
----------------------------------------------------------------------
Ran 3 tests in 0.003s
OK
check-components guard: all selected cases passed
```

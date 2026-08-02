"""Declarative Aiur Build publication extensions for this planning pack."""

from __future__ import annotations


AIUR_BUILD_PUBLICATION_ADAPTER_VERSION = 1


def publication_extension() -> dict[str, object]:
    """Declare only behavior beyond the canonical root-and-ticket graph."""
    return {
        "additional_issue": {
            "manifest_key": "skill_issue",
            "labels": ["human:todo"],
        },
        "external_edges_field": "external_blocker_relations",
        "feature_title_prefix": "BO:",
        "additional_title_must_be_unprefixed": True,
        "reconciliation_comment": True,
        "creatable_labels": {
            "build-order": ["5319e7", "Build Order planning root"],
            "build-lane:plan-graph": ["bfdadc", "Build Order lane: plan graph"],
            "build-lane:runtime": ["bfdadc", "Build Order lane: runtime"],
            "build-lane:dashboard-ui": ["bfdadc", "Build Order lane: dashboard UI"],
            "build-lane:accounting": ["bfdadc", "Build Order lane: accounting"],
            "build-lane:platform": ["bfdadc", "Build Order lane: platform"],
            "phase:7": ["d4c5f9", "Build Order phase 7"],
            "phase:8": ["d4c5f9", "Build Order phase 8"],
        },
        "extra_validator": "scripts/validate_publication.py",
    }

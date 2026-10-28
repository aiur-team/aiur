"""Newsletter work kinds mirror Aiur.RunTelemetry.Cohort for the main base."""
import re


def main_fix(labels):
    return any(label.lower() == "main-fix" or label.lower().startswith("main-fix:") for label in labels)


def classify(labels, title=""):
    if "build-order" in labels or any(label.startswith(("feature:", "build-lane:")) for label in labels):
        return "feature"
    normalized = [label.lower() for label in labels]
    if re.search(r"\b(test|flake|ci|quarantine)\b", title or "", re.I) or any(
            "flake" in label or "test" in label or
            (label.endswith("-fix") and label.startswith("main-fix")) for label in normalized):
        return "test_ci"
    if re.search(r"\b(tooling|chore|dependency|deps)\b", title or "", re.I) or any(
            "tooling" in label or "chore" in label for label in normalized):
        return "tooling"
    return "other"

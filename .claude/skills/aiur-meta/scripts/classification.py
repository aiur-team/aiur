"""The feature-share rule, shared by the meta check and newsletter collector."""
import re
import sys


def classify(text):
    if any(word in text for word in ("build-lane:", "feature:", "build-order")):
        return "feature"
    if re.match(r"^MP-[A-Z0-9]+(-[A-Z0-9]+)*", text):
        return "feature"
    if re.search(r"flak|test|quarantin|(^|[^a-z])ci([^a-z]|$)|merge.group|soak|coverage", text, re.I):
        return "test_ci"
    return "other"


if __name__ == "__main__":
    print(classify(sys.argv[1]), end="")

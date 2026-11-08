"""Title rules for published Build Order tickets."""

from __future__ import annotations

import re


def has_logical_id_prefix(title: str, logical_id: str) -> bool:
    return title == logical_id or re.match(
        rf"^{re.escape(logical_id)}(?:\s|—|-)", title,
    ) is not None

"""Keep every unfinished lane, with readable labels instead of tracker slugs."""
from presentation import numeric, progress_row, shown, value

# Product names from the mobile/platform planning packs and dashboard vocabulary.
NAMES = {"mp-n1": "Mobile foundations", "mp-n2": "Device pairing", "mp-n3": "Instance summaries",
         "mp-n4": "Push relay", "mp-n5": "Notification controls", "mp-n6": "Mobile app",
         "mp-n7": "Watch companion", "home": "Home page", "acceptance": "Acceptance tests",
         "harness": "Agent harness", "streamdeck-redesign": "Stream Deck redesign",
         "refactor-units": "Unit refactor"}
WORDS = {"streamdeck": "Stream Deck", "ui": "UI", "cli": "CLI", "api": "API", "ci": "CI",
         "paseo": "Paseo", "nuc": "NUC", "pc": "PC"}


def name(key, row):
    if isinstance(value(row.get("name")), str):
        return value(row["name"])
    slug = key.removeprefix("feature:").removeprefix("build-lane:")
    if slug in NAMES:
        return NAMES[slug]
    words = [WORDS.get(word.lower(), word) for word in slug.replace('-', ' ').replace('_', ' ').split()]
    label = ' '.join(words)
    return label[:1].upper() + label[1:]


def rows(program):
    lanes = program.get("lanes")
    if not isinstance(lanes, dict):
        return shown(None)
    unfinished = [(key, row) for key, row in lanes.items()
                  if numeric(row.get("done")) is None or numeric(row.get("total")) is None
                  or numeric(row["done"]) < numeric(row["total"])]
    unfinished.sort(key=lambda pair: (-(numeric(pair[1].get("done_in_window")) or 0), pair[0]))
    return ''.join('<div data-lane="true">' + progress_row(name(key, row), row) + '</div>'
                   for key, row in unfinished) or '<p>None remaining</p>'

"""Inline shared Aiur assets so printing never fetches fonts or styles."""
import base64
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
STYLE = HERE.parent / "aiur-style"


def data_url(path, mime):
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode("ascii")


def styles():
    definitions = json.loads((STYLE / "src/tokens/tokens.json").read_text())

    def resolve(name):
        item = definitions[name]
        value = item.get("dark", item.get("value"))
        if isinstance(value, dict):
            value = value["dark"]
        return resolve(value[1:-1]) if value.startswith("{") else value

    aliases = {"bg": "bg-app", "muted": "muted-app", "faint": "faint",
               "attn": "attention", "attn-ink": "attention-ink", "attn-soft": "attention-soft",
               "attn-line": "attention-line", "block": "blocking", "block-ink": "blocking-ink",
               "block-soft": "blocking-soft", "good": "good", "good-ink": "good-ink",
               "good-soft": "good-soft", "super": "super", "super-ink": "super-ink",
               "super-soft": "super-soft"}
    variables = []
    for name in ("bg", "surface", "surface-2", "surface-3", "fg", "muted", "faint", "accent",
                 "accent-ink", "line", "line-strong", "hairline", "accent-soft", *list(aliases)[3:]):
        variables.append(f"--{name}:{resolve('color.' + aliases.get(name, name))}")
    fonts = (("Fraunces", "Fraunces-Latin.woff2", "400 700"),
             ("Space Grotesk", "SpaceGrotesk-Variable.woff2", "300 700"),
             ("JetBrains Mono", "JetBrainsMono-Variable.woff2", "100 800"),
             ("Bungee", "Bungee-Regular.woff2", "400"))
    faces = [f'@font-face{{font-family:"{family}";src:url({data_url(STYLE / "fonts" / file, "font/woff2")}) '
             f'format("woff2");font-weight:{weight};font-display:block}}' for family, file, weight in fonts]
    return ":root{" + ";".join(variables) + "}" + "".join(faces) + (HERE / "template.css").read_text()


ICONS = json.loads((HERE / "icons.json").read_text())


def icon(name):
    return ICONS.get(name, ICONS["git-branch"])

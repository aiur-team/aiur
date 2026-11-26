"""Resolve explicit nested config ownership using the docs checker's schema inventory."""
import importlib.util
from pathlib import Path


def nested_config_keys(root):
    spec = importlib.util.spec_from_file_location('config_docs', Path(__file__).resolve().parents[1] / 'check-config-docs.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    keys = {}
    schema = module.Root(root / 'src/lib/aiur/config/schema.ex', 'Aiur.Config.Schema')
    module.collect(module.load_modules(schema), schema.module, '', set(), keys, schema)
    return {key for key in keys if '.' in key}

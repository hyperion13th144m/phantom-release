import argparse
import importlib.metadata
import json
import sys
from pathlib import Path

import tomllib


def get_project_version(name: str, pyproject_path: Path) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        project = tomllib.loads(pyproject_path.read_text(encoding="utf-8"))["project"]
        return str(project["version"])


parser = argparse.ArgumentParser()
parser.add_argument(
    "package",
    help="target package to generate OpenAPI schema (e.g. mona, crow, panther)",
    choices=["mona", "crow", "panther"],
)
parser.add_argument("output_dir", help="output directory")

args = parser.parse_args()
if args.package == "mona":
    from mona.server import app
elif args.package == "crow":
    from crow.server import app
elif args.package == "panther":
    from panther.server import app
else:
    print(f"Invalid package: {args.package}")
    sys.exit(1)

PROJECT_ROOT = Path(__file__).resolve().parents[1]
PYPROJECT_PATH = PROJECT_ROOT / "services" / args.package / "pyproject.toml"
version = get_project_version(args.package, PYPROJECT_PATH)
filename = Path(args.output_dir) / f"{args.package}-{version}.json"
schema = app.openapi()
filename.write_text(json.dumps(schema, indent=2), encoding="utf-8")

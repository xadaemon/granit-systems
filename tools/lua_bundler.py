#! /usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def find_requires(content):
    """Find all module names in require() calls."""
    pattern = r'require\s*\(\s*["\']([^"\']+)["\']\s*\)'
    return re.findall(pattern, content)


def resolve_module(module_name, base_path):
    """Resolve a module name to a Lua file path."""
    base_dir = Path(base_path).parent

    # Handle relative paths (./module, ../parent/module)
    if module_name.startswith(("./", "../")):
        candidate = Path(base_dir) / module_name
        if candidate.exists():
            return str(candidate)
        candidate_init = candidate / "init.lua"
        if candidate_init.exists():
            return str(candidate_init)
        return None

    # Convert dots to path separators (a.b.c -> a/b/c)
    path_parts = module_name.replace(".", os.sep)

    # Try {module}.lua
    candidate = Path(base_dir) / f"{path_parts}.lua"
    if candidate.exists():
        return str(candidate)

    # Try {module}/init.lua
    candidate_dir = Path(base_dir) / path_parts
    candidate_init = candidate_dir / "init.lua"
    if candidate_init.exists():
        return str(candidate_init)

    return None


def process_file(filepath, processing, processed):
    """Recursively process a Lua file and its dependencies."""
    if filepath in processing:
        raise RuntimeError(f"Circular dependency detected involving: {filepath}")
    if filepath in processed:
        return ""

    processing.add(filepath)
    content = Path(filepath).read_text(encoding="utf-8")
    requires = find_requires(content)
    for required in requires:
        print(f"Found requirement {required} in {filepath}")

    all_content = ""
    for req in requires:
        dep_path = resolve_module(req, filepath)
        if dep_path is None:
            raise RuntimeError(f"Cannot resolve require('{req}') in {filepath}")
        dep_content = process_file(dep_path, processing, processed)
        all_content += dep_content + "\n"

    processing.remove(filepath)
    processed.add(filepath)
    all_content += content + "\n"

    # finally remove any require lines
    all_content = re.sub(r'require\s*\(\s*[\'"]([^\'"]+)[\'"]\s*\)', "", all_content)

    return all_content


def main():
    if len(sys.argv) != 2:
        print("Usage: python lua_concat.py <input.lua>", file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    input_file = Path(input_path)
    temp_path = None

    if not input_file.exists():
        print(f"Error: File not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    output = process_file(str(input_file), set(), set())
    with open(f"{input_file.stem}.combi.lua", encoding="utf-8", mode="w") as f:
        f.write(output)


if __name__ == "__main__":
    main()

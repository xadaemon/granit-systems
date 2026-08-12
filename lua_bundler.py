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
    all_content = re.sub(r'require\s*\(\s*[\'"]([^\'"]+)[\'"]\s*\)', '', all_content)

    return all_content


def main():
    if len(sys.argv) != 2:
        print("Usage: python lua_concat.py <input.lua>", file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    max_out_size = int(sys.argv[2]) if len(sys.argv) > 3 else 8192
    input_file = Path(input_path)
    temp_path = None

    if not input_file.exists():
        print(f"Error: File not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    try:
        output = process_file(str(input_file), set(), set())

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".lua", delete=False, encoding="utf-8"
        ) as f:
            f.write(output)
            temp_path = f.name

        result = subprocess.run(
            ["luamin", "-f", temp_path], capture_output=True, text=True, check=True
        )

        minified = result.stdout
        if len(minified) > max_out_size:
            print(f"Error: Minified output exceeds {max_out_size} bytes", file=sys.stderr)
            sys.exit(1)

        output_path = str(input_file) + ".min.lua"
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(minified)

        print(f"Minified output {len(minified)} long saved to: {output_path}")

    except subprocess.CalledProcessError as e:
        print(f"luamin failed: {e.stderr}", file=sys.stderr)
        sys.exit(1)
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        try:
            if temp_path:
                os.unlink(temp_path)
        except NameError:
            pass

if __name__ == "__main__":
    main()

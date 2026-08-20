# helpers to build libs


build:
    @echo "building all libs"
    rm -rf out
    cyan build
    just minify-lua "./out"

test: test-lua test-py

test-lua:
    cd Libraries/Platform_Link && tl run Test_Plink.tl

test-py:
    pytest Libraries/Platform_Link_Py

minify-lua subdirectory:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{subdirectory}}" ]; then
        echo "Error: subdirectory argument is required."
        exit 1
    fi
    find "{{subdirectory}}" -type f -name "*.lua" | while read -r lua_file; do
        echo "minify $lua_file"
        out=$(luamin -c < "$lua_file")
        cat "banner.txt" > $lua_file
        echo $out >> $lua_file
    done
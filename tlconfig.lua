return {
    include_dir = {
        "Libraries/Platform_Link"
    },
    exclude = {
        "**/test_*",
        "**/Test_*"
    },
    gen_target = "5.3",
    gen_compat = "off",
    source_dir = "Libraries",
    build_dir = "out"
}
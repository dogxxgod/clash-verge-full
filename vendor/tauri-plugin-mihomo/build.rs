const COMMANDS: &[&str] = &[
    "update_controller",
    "update_secret",
    "get_version",
    "flush_fakeip",
    "flush_dns",
    "get_connections",
    "close_all_connections",
    "close_connection",
    "get_groups",
    "get_group_by_name",
    "delay_group",
    "get_proxy_providers",
    "get_proxy_provider_by_name",
    "update_proxy_provider",
    "healthcheck_proxy_provider",
    "healthcheck_node_in_provider",
    "get_proxies",
    "get_proxy_by_name",
    "select_node_for_group",
    "unfixed_proxy",
    "delay_proxy_by_name",
    "get_rules",
    "get_rule_providers",
    "update_rule_provider",
    "get_base_config",
    "reload_config",
    "patch_base_config",
    "update_geo",
    "restart",
    "upgrade_core",
    "upgrade_ui",
    "upgrade_geo",
    "ws_traffic",
    "ws_memory",
    "ws_connections",
    "ws_connections_count",
    "ws_logs",
    "ws_disconnect",
    "clear_all_ws_connections",
];

fn main() {
    // The plugin is pure Rust: it ships no Kotlin project and no Swift package. Declaring
    // `android_path`/`ios_path` would make the mobile builds try to include a module that does
    // not exist — on iOS that panics inside tauri-utils' `link_apple_library` because it runs
    // `xcodebuild` with a `cwd` that is missing. The Rust API works on both platforms without it.
    tauri_plugin::Builder::new(COMMANDS).build();
}

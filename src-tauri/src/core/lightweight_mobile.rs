//! Lightweight mode hides the desktop window; mobile apps are backgrounded by the OS instead, so
//! every operation reports the normal state.

use anyhow::Result;

pub const fn is_in_lightweight_mode() -> bool {
    false
}

pub async fn auto_lightweight_boot() -> Result<()> {
    Ok(())
}

pub async fn enable_auto_light_weight_mode() {}

pub fn disable_auto_light_weight_mode() {}

pub async fn entry_lightweight_mode() -> bool {
    false
}

pub async fn exit_lightweight_mode() -> bool {
    false
}

pub async fn add_light_weight_timer() {}

//! Android/iOS have no per-application system proxy to configure; every operation is a no-op so
//! shared configuration code can keep calling the same interface.

use crate::singleton;
use anyhow::Result;

#[derive(Default)]
pub(crate) struct Sysopt;

singleton!(Sysopt, SYSOPT);

impl Sysopt {
    const fn new() -> Self {
        Self
    }

    /// No pending OS writes exist on mobile.
    pub(crate) async fn wait_idle(&self) {}

    pub(super) async fn update_sysproxy(&self) -> Result<()> {
        Ok(())
    }

    pub(super) async fn reset_sysproxy(&self) -> Result<()> {
        Ok(())
    }

    pub(super) async fn stop_proxy_guard(&self) -> bool {
        true
    }

    pub(super) async fn refresh_guard(&self) -> bool {
        false
    }
}

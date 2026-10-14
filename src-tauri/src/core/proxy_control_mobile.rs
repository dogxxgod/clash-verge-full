//! Mobile platforms have no system proxy to write; the operations are accepted as no-ops so the
//! shared core lifecycle keeps its single call pattern.

use anyhow::Result;

/// Actionable system-proxy failure attached to an `anyhow` chain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SysproxyFailure {
    /// A local `networksetup` write lacked privileges.
    PrivilegeRequired,
    /// The service failed to apply the proxy and attempted direct fallback.
    DirectFallback { detail: String },
    /// A ready service can replace the refused sidecar write.
    SidecarWhileServiceReady,
    /// The proxy guard stopped after repeated failures.
    GuardStopped { detail: String },
    /// The Core was not ready, so enabling the system proxy was refused.
    CoreNotReady,
    /// A Windows system call refused the write, usually a transient RPC hiccup.
    SystemCallFailed,
}

impl SysproxyFailure {
    #[inline]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::PrivilegeRequired => "SYSPROXY_PRIVILEGE_REQUIRED",
            Self::DirectFallback { .. } => "SYSPROXY_DIRECT_FALLBACK",
            Self::SidecarWhileServiceReady => "SYSPROXY_SIDECAR_WHILE_SERVICE_READY",
            Self::GuardStopped { .. } => "SYSPROXY_GUARD_STOPPED",
            Self::CoreNotReady => "SYSPROXY_CORE_NOT_READY",
            Self::SystemCallFailed => "SYSPROXY_SYSTEM_CALL_FAILED",
        }
    }

    #[inline]
    pub fn from_chain(error: &anyhow::Error) -> Option<&Self> {
        error.downcast_ref::<Self>()
    }
}

impl std::fmt::Display for SysproxyFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PrivilegeRequired => f.write_str("system proxy write requires elevated privileges"),
            Self::DirectFallback { detail } => {
                write!(f, "system proxy failed and fell back to direct: {detail}")
            }
            Self::SidecarWhileServiceReady => {
                f.write_str("system proxy write was refused locally while the service was ready")
            }
            Self::GuardStopped { detail } => {
                write!(f, "system proxy guard stopped after repeated failures: {detail}")
            }
            Self::CoreNotReady => f.write_str("the core is not ready, so the system proxy was not enabled"),
            Self::SystemCallFailed => f.write_str("a system call failed while writing the system proxy"),
        }
    }
}

impl std::error::Error for SysproxyFailure {}

/// Marker for a partially applied system proxy write.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SystemProxyStateUnknown;

impl SystemProxyStateUnknown {
    #[inline]
    pub fn is_in(error: &anyhow::Error) -> bool {
        error.downcast_ref::<Self>().is_some()
    }
}

impl std::fmt::Display for SystemProxyStateUnknown {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the system proxy was left partly applied; turning it off was attempted")
    }
}

impl std::error::Error for SystemProxyStateUnknown {}

#[inline]
fn carries_a_mappable_code(error: &anyhow::Error) -> bool {
    SysproxyFailure::from_chain(error).is_some()
}

/// Combine a cause with rollback failure without hiding actionable classifications.
pub fn rollback_failure(caused_by: anyhow::Error, rollback: anyhow::Error) -> anyhow::Error {
    let state_unknown = SystemProxyStateUnknown::is_in(&caused_by) || SystemProxyStateUnknown::is_in(&rollback);

    let combined = if carries_a_mappable_code(&caused_by) || !carries_a_mappable_code(&rollback) {
        caused_by.context(format!("the rollback that followed also failed: {rollback:#}"))
    } else {
        rollback.context(format!("this rollback followed an earlier failure: {caused_by:#}"))
    };

    if state_unknown && !SystemProxyStateUnknown::is_in(&combined) {
        return combined.context(SystemProxyStateUnknown);
    }
    combined
}

pub const fn is_reportable(_error: &anyhow::Error) -> bool {
    false
}

pub async fn has_network_service() -> bool {
    false
}

pub async fn apply() -> Result<()> {
    Ok(())
}

pub async fn clear() -> Result<()> {
    Ok(())
}

pub async fn refresh_guard() -> Result<()> {
    Ok(())
}

pub async fn stop_guard() -> bool {
    true
}

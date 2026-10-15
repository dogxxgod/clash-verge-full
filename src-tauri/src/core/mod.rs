pub mod auto_backup;
#[cfg(desktop)]
pub mod autostart;
#[cfg(mobile)]
#[path = "autostart_mobile.rs"]
pub mod autostart;
pub mod backup;
#[cfg(desktop)]
pub mod hotkey;
#[cfg(mobile)]
#[path = "hotkey_mobile.rs"]
pub mod hotkey;
#[cfg(desktop)]
pub mod lightweight;
#[cfg(mobile)]
#[path = "lightweight_mobile.rs"]
pub mod lightweight;
pub mod listener;
pub mod logger;
pub mod manager;
#[cfg(target_os = "macos")]
pub mod network_watch;
pub mod notify;
pub(crate) mod owner_identity;
#[cfg(desktop)]
pub mod proxy_control;
#[cfg(mobile)]
#[path = "proxy_control_mobile.rs"]
pub mod proxy_control;
pub mod proxy_view;
pub mod runstate;
pub(crate) mod runtime_bundle;
pub mod service;
#[cfg(desktop)]
pub mod sysopt;
#[cfg(mobile)]
#[path = "sysopt_mobile.rs"]
pub mod sysopt;
pub mod timer;
#[cfg(desktop)]
pub mod tray;
#[cfg(mobile)]
#[path = "tray_mobile.rs"]
pub mod tray;
#[cfg(desktop)]
pub mod updater;
#[cfg(mobile)]
#[path = "updater_mobile.rs"]
pub mod updater;
pub mod validate;
pub mod win_uwp;
#[cfg(target_os = "android")]
pub mod tun_android;

pub use self::{manager::CoreManager, timer::Timer};
pub use self::updater::SilentUpdater;
pub use notify::{handle, notification};

//! Global hotkeys are a desktop concept; registration is a no-op on mobile.

use crate::singleton;
use anyhow::Result;
use smartstring::alias::String;

#[derive(Debug, Clone, Copy)]
pub enum HotkeyFunction {
    OpenOrCloseDashboard,
    ClashMode,
    SystemProxy,
    TunMode,
    EntryLightweight,
}

#[derive(Debug, Clone, Copy)]
pub enum SystemHotkey {
    CmdQ,
    CmdW,
}

pub struct Hotkey;

singleton!(Hotkey, HOTKEY);

impl Hotkey {
    const fn new() -> Self {
        Self
    }

    pub async fn register_system_hotkey(&self, _hotkey: SystemHotkey) -> Result<()> {
        Ok(())
    }

    pub fn unregister_system_hotkey(&self, _hotkey: SystemHotkey) -> Result<()> {
        Ok(())
    }

    pub async fn register_hotkey_with_function(&self, _hotkey: &str, _function: HotkeyFunction) -> Result<()> {
        Ok(())
    }

    pub async fn init(&self, _skip: bool) -> Result<()> {
        Ok(())
    }

    pub fn reset(&self) -> Result<()> {
        Ok(())
    }

    pub async fn register(&self, _hotkey: &str, _func: &str) -> Result<()> {
        Ok(())
    }

    pub fn unregister(&self, _hotkey: &str) -> Result<()> {
        Ok(())
    }

    pub async fn update(&self, _new_hotkeys: Vec<String>) -> Result<()> {
        Ok(())
    }
}

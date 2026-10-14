//! No system tray exists on mobile; every operation is a no-op so shared configuration code can
//! keep calling the same interface.

use crate::singleton;
use anyhow::Result;

pub struct Tray;

singleton!(Tray, TRAY);

impl Tray {
    const fn new() -> Self {
        Self
    }

    pub async fn init(&self) -> Result<()> {
        Ok(())
    }

    pub async fn update_menu(&self) -> Result<()> {
        Ok(())
    }

    pub async fn update_menu_and_icon(&self) {}

    pub async fn update_tooltip(&self) -> Result<()> {
        Ok(())
    }

    pub async fn update_click_behavior(&self) -> Result<()> {
        Ok(())
    }

    pub async fn update_part(&self) -> Result<()> {
        Ok(())
    }

    pub async fn update_icon(&self, _verge: &crate::config::IVerge) -> Result<()> {
        Ok(())
    }

    pub async fn update_speed_task(&self, _enabled: bool) {}
}

import { getCurrentWindow } from '@tauri-apps/api/window'

import getSystem from '@/utils/get-system'

// Android reports the window as not visible even while it is in the foreground
// (`Window::is_visible` is a no-op there) and never registers `is_minimized`,
// so mobile has to read the WebView's own state instead of probing the window.
const isMobileOS = ['android', 'ios'].includes(getSystem())

export const isDocumentVisible = () =>
  typeof document === 'undefined' || document.visibilityState === 'visible'

/**
 * Whether the user is looking at a window that can show a notice.
 *
 * Fails closed only when the platform check itself is unusable, so a notice is
 * never shown for a window the user cannot see.
 */
export const isWindowWatched = async () => {
  if (isMobileOS) return isDocumentVisible()

  try {
    const window = getCurrentWindow()
    const [visible, minimized] = await Promise.all([
      window.isVisible(),
      window.isMinimized(),
    ])
    return visible && !minimized
  } catch (error) {
    console.warn('[window] window state unavailable:', error)
    return false
  }
}

// get the system os
// according to UA
export default function getSystem() {
  const ua = navigator.userAgent
  const platform = OS_PLATFORM

  if (/android/i.test(ua)) return 'android'

  // WKWebView reports "like Mac OS X" on both iPhone and iPad, so this has to be
  // decided before the macOS branch.
  if (/iphone|ipad|ipod/i.test(ua)) return 'ios'

  if (ua.includes('Mac OS X') || platform === 'darwin') return 'macos'

  if (/win64|win32/i.test(ua) || platform === 'win32') return 'windows'

  if (/linux/i.test(ua)) return 'linux'

  return 'unknown'
}

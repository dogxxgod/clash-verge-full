package io.github.clashverge.rev

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.util.Log
import androidx.activity.enableEdgeToEdge

/**
 * Replaces the stub emitted by `tauri android init`: the VPN flow needs the live
 * activity to host the system consent dialog and to start the tunnel service,
 * and Rust reaches both through the `@JvmStatic` companions below.
 */
class MainActivity : TauriActivity() {
  companion object {
    private const val TAG = "MainActivity"
    private const val VPN_REQUEST_CODE = 0x5650 // 'VP'
    @JvmStatic var instance: MainActivity? = null
      private set

    @JvmStatic
    fun requestVpnPermission(): Boolean {
      val activity = instance ?: return false
      val intent = VpnService.prepare(activity)
      return if (intent != null) {
        activity.startActivityForResult(intent, VPN_REQUEST_CODE)
        false
      } else {
        true
      }
    }

    @JvmStatic
    fun startVpnService(): Boolean {
      val activity = instance ?: return false
      val intent = Intent(activity, VpnTunService::class.java).apply {
        action = VpnTunService.ACTION_START
      }
      activity.startService(intent)
      return true
    }

    @JvmStatic
    fun stopVpnService(): Boolean {
      val activity = instance ?: return false
      val intent = Intent(activity, VpnTunService::class.java).apply {
        action = VpnTunService.ACTION_STOP
      }
      activity.startService(intent)
      return true
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
    instance = this
  }

  override fun onDestroy() {
    if (instance == this) {
      instance = null
    }
    super.onDestroy()
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (requestCode == VPN_REQUEST_CODE) {
      if (resultCode == RESULT_OK) {
        Log.i(TAG, "VPN permission granted by user, starting VpnTunService")
        startVpnService()
      } else {
        Log.w(TAG, "VPN permission denied by user")
      }
    }
  }
}

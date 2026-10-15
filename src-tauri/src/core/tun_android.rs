//! Android VPN / TUN integration for Clash Verge.
//!
//! Provides JNI callbacks and state coordination between the Android `VpnTunService`
//! and the mihomo core runner.

use std::os::fd::RawFd;
use std::sync::atomic::{AtomicI32, Ordering};
use clash_verge_logging::{Type, logging};

static TUN_FD: AtomicI32 = AtomicI32::new(-1);

/// Stores the active TUN file descriptor.
pub fn set_tun_fd(fd: RawFd) {
    // Clear FD_CLOEXEC so that the child sidecar process (mihomo) inherits the descriptor across exec.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 {
            let _ = libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC);
        }
    }
    TUN_FD.store(fd, Ordering::SeqCst);
    logging!(info, Type::Core, "Android TUN FD registered: {fd}");
}

/// Clears the TUN file descriptor.
pub fn clear_tun_fd() {
    let old = TUN_FD.swap(-1, Ordering::SeqCst);
    if old >= 0 {
        logging!(info, Type::Core, "Android TUN FD cleared (was {old})");
        unsafe {
            libc::close(old);
        }
    }
}

/// Gets the current active TUN file descriptor, if any.
pub fn get_tun_fd() -> Option<RawFd> {
    let fd = TUN_FD.load(Ordering::SeqCst);
    if fd >= 0 {
        Some(fd)
    } else {
        None
    }
}

fn get_main_activity_class<'a>(
    env: &mut jni::JNIEnv<'a>,
) -> anyhow::Result<jni::objects::JClass<'a>> {
    let ctx = ndk_context::android_context();
    let app_context = unsafe { jni::objects::JObject::from_raw(ctx.context().cast()) };

    // Get ClassLoader from ApplicationContext
    let class_loader = env
        .call_method(&app_context, "getClassLoader", "()Ljava/lang/ClassLoader;", &[])?
        .l()?;

    let class_name = env.new_string("io.github.clashverge.rev.MainActivity")?;
    let class_obj = env
        .call_method(
            &class_loader,
            "loadClass",
            "(Ljava/lang/String;)Ljava/lang/Class;",
            &[jni::objects::JValue::Object(&class_name)],
        )?
        .l()?;

    Ok(class_obj.into())
}

/// Invokes MainActivity.startVpnService() via JNI.
pub fn start_vpn_service() -> anyhow::Result<()> {
    let ctx = ndk_context::android_context();
    let vm = unsafe { jni::JavaVM::from_raw(ctx.vm().cast()) }?;
    let mut env = vm.attach_current_thread()?;

    let class = get_main_activity_class(&mut env)?;

    // First ensure permission is requested/ready
    let has_perm = env.call_static_method(&class, "requestVpnPermission", "()Z", &[])?.z()?;
    logging!(info, Type::Core, "MainActivity.requestVpnPermission returned: {has_perm}");

    if has_perm {
        let started = env.call_static_method(&class, "startVpnService", "()Z", &[])?.z()?;
        logging!(info, Type::Core, "MainActivity.startVpnService returned: {started}");
    }
    Ok(())
}

/// Asynchronously starts the VPN service and waits for the TUN file descriptor.
pub async fn start_vpn_service_and_wait_fd(timeout: std::time::Duration) -> anyhow::Result<RawFd> {
    if let Some(fd) = get_tun_fd() {
        return Ok(fd);
    }
    start_vpn_service()?;
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if let Some(fd) = get_tun_fd() {
            return Ok(fd);
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    anyhow::bail!("Timeout waiting for TUN FD to be established by VpnService")
}

/// Invokes MainActivity.stopVpnService() via JNI.
pub fn stop_vpn_service() -> anyhow::Result<()> {
    let ctx = ndk_context::android_context();
    let vm = unsafe { jni::JavaVM::from_raw(ctx.vm().cast()) }?;
    let mut env = vm.attach_current_thread()?;

    let class = get_main_activity_class(&mut env)?;
    let stopped = env.call_static_method(&class, "stopVpnService", "()Z", &[])?.z()?;
    logging!(info, Type::Core, "MainActivity.stopVpnService returned: {stopped}");
    clear_tun_fd();
    Ok(())
}

// JNI exports called from io.github.clashverge.rev.VpnTunService

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn Java_io_github_clashverge_rev_VpnTunService_nativeOnTunEstablished(
    _env: jni::JNIEnv,
    _class: jni::objects::JClass,
    fd: jni::sys::jint,
) {
    logging!(info, Type::Core, "JNI: nativeOnTunEstablished called with fd={fd}");
    set_tun_fd(fd as RawFd);
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn Java_io_github_clashverge_rev_VpnTunService_nativeOnTunRevoked(
    _env: jni::JNIEnv,
    _class: jni::objects::JClass,
) {
    logging!(info, Type::Core, "JNI: nativeOnTunRevoked called");
    clear_tun_fd();
}

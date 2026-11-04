package com.jaminxx.zpill.usb

/**
 * USB 端口复位的 JNI 入口(见 cpp/usb_reset.c)。
 *
 * Android 没有公开的 resetDevice() API;对 UsbDeviceConnection 的 usbfs
 * fd 发 USBDEVFS_RESET,强制相机重枚举、复位 PTP 栈。返回 0 = 成功,
 * 负 errno = 失败(调用方按能力不可用降级)。
 */
internal object UsbResetNative {
    init {
        System.loadLibrary("usbreset")
    }

    /** @return 0 成功;负值 = -errno。 */
    @JvmStatic
    external fun reset(fd: Int): Int
}

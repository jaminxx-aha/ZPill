// USB 端口复位:对 UsbDeviceConnection.getFileDescriptor() 返回的 usbfs
// fd 发 USBDEVFS_RESET,等价 ohos @ohos.usb 的 resetUsbDevice(相机对
// 同枚举的新会话沉默时,强制重枚举让相机 PTP 栈复位)。
//
// Android 公开 API 没有 resetDevice();UsbDeviceConnection 的 fd 就是
// 系统 open 的 /dev/bus/usb/... usbfs fd,libusbhost 内部复位用的也是
// 同一个 ioctl。
#include <jni.h>
#include <errno.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

#ifndef USBDEVFS_RESET
#define USBDEVFS_RESET _IO('U', 20)
#endif

JNIEXPORT jint JNICALL
Java_com_jaminxx_zpill_usb_UsbResetNative_reset(JNIEnv *env, jclass clazz,
                                                jint fd) {
    (void)env;
    (void)clazz;
    if (fd < 0) return -EBADF;
    if (ioctl(fd, USBDEVFS_RESET, 0) != 0) return -errno;
    return 0;
}

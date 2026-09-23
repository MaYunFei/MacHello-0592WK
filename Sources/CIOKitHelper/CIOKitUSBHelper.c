#include "CIOKitHelper.h"
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>

#define VENDOR_ID    0x0bda
#define PRODUCT_ID   0x5767
#define UVC_UNIT_ID  0x04
#define INTERFACE_NUM 0x00

static int send_xu(IOUSBDeviceInterface **dev, uint8_t selector, uint8_t req_type, uint8_t req, uint8_t *data, uint16_t len) {
    IOUSBDevRequest dev_req;
    memset(&dev_req, 0, sizeof(dev_req));
    dev_req.bmRequestType = req_type;
    dev_req.bRequest = req;
    dev_req.wValue = selector << 8;
    dev_req.wIndex = (UVC_UNIT_ID << 8) | INTERFACE_NUM;
    dev_req.wLength = len;
    dev_req.pData = data;

    IOReturn kr = (*dev)->DeviceRequest(dev, &dev_req);
    if (kr != kIOReturnSuccess) {
        return -1;
    }
    return dev_req.wLenDone;
}

bool dell_camera_is_connected(void) {
    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchingDict) return false;

    SInt32 vid = VENDOR_ID;
    SInt32 pid = PRODUCT_ID;
    CFNumberRef vidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vid);
    CFNumberRef pidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID), vidRef);
    CFDictionarySetValue(matchingDict, CFSTR(kUSBProductID), pidRef);
    CFRelease(vidRef);
    CFRelease(pidRef);

    io_iterator_t iterator;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator);
    if (kr != KERN_SUCCESS) return false;

    io_service_t usbDeviceRef = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!usbDeviceRef) return false;

    IOObjectRelease(usbDeviceRef);
    return true;
}

int dell_camera_set_mode(uint8_t mode) {
    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchingDict) return -1;

    SInt32 vid = VENDOR_ID;
    SInt32 pid = PRODUCT_ID;
    CFNumberRef vidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vid);
    CFNumberRef pidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID), vidRef);
    CFDictionarySetValue(matchingDict, CFSTR(kUSBProductID), pidRef);
    CFRelease(vidRef);
    CFRelease(pidRef);

    io_iterator_t iterator;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator);
    if (kr != KERN_SUCCESS) return -2;

    io_service_t usbDeviceRef = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!usbDeviceRef) return -3;

    IOCFPlugInInterface **plugInInterface = NULL;
    SInt32 score;
    kr = IOCreatePlugInInterfaceForService(usbDeviceRef,
                                          kIOUSBDeviceUserClientTypeID,
                                          kIOCFPlugInInterfaceID,
                                          &plugInInterface,
                                          &score);
    IOObjectRelease(usbDeviceRef);
    if (kr != KERN_SUCCESS || !plugInInterface) return -4;

    IOUSBDeviceInterface **dev = NULL;
    HRESULT result = (*plugInInterface)->QueryInterface(plugInInterface,
                                                        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                                        (LPVOID *)&dev);
    (*plugInInterface)->Release(plugInInterface);
    if (result || !dev) return -5;

    kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) {
        kr = (*dev)->USBDeviceOpenSeize(dev);
        if (kr != kIOReturnSuccess) {
            (*dev)->Release(dev);
            return -6;
        }
    }

    uint8_t buf[8];
    // Step 1: Reset
    memset(buf, 0, 8); buf[0] = 0xff;
    int r = send_xu(dev, 0x0a, 0x21, 0x01, buf, 8);
    if (r < 0) { (*dev)->USBDeviceClose(dev); (*dev)->Release(dev); return -11; }

    // Step 2: Address 0xfb00
    memset(buf, 0, 8); buf[0] = 0x00; buf[1] = 0xfb; buf[4] = 0x05;
    r = send_xu(dev, 0x0a, 0x21, 0x01, buf, 8);
    if (r < 0) { (*dev)->USBDeviceClose(dev); (*dev)->Release(dev); return -12; }

    // Step 3: Read handshake
    memset(buf, 0, 8);
    r = send_xu(dev, 0x0b, 0xa1, 0x81, buf, 8);
    if (r < 0) { (*dev)->USBDeviceClose(dev); (*dev)->Release(dev); return -13; }

    // Step 4: Address 0x9f00
    memset(buf, 0, 8); buf[0] = 0x00; buf[1] = 0x9f; buf[4] = 0x01;
    r = send_xu(dev, 0x0a, 0x21, 0x01, buf, 8);
    if (r < 0) { (*dev)->USBDeviceClose(dev); (*dev)->Release(dev); return -14; }

    // Step 5: Write mode (0x00 for IR, 0x01 for RGB)
    memset(buf, 0, 8); buf[0] = mode;
    r = send_xu(dev, 0x0b, 0x21, 0x01, buf, 8);
    if (r < 0) { (*dev)->USBDeviceClose(dev); (*dev)->Release(dev); return -15; }

    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return 0;
}

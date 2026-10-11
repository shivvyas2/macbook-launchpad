#include "MultitouchBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

// Layout of a contact as reported by MultitouchSupport.framework (private, but stable for years).
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, fingerID, handID;
    MTVector normalized;
    float size;
    int zero1;
    float angle, majorAxis, minorAxis;
    MTVector absolute;
    int zero2[2];
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFMutableArrayRef (*pMTDeviceCreateList)(void);
static void (*pMTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTUnregisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTDeviceStart)(MTDeviceRef, int);
static void (*pMTDeviceStop)(MTDeviceRef);

static MTBFrameHandler gHandler;
static CFMutableArrayRef gDevices;

#define MAX_TOUCHES 16

static int contactCallback(MTDeviceRef device, MTTouch *touches, int count, double timestamp, int frame) {
    (void)device; (void)frame;
    if (!gHandler) return 0;
    float xs[MAX_TOUCHES], ys[MAX_TOUCHES];
    int n = count < MAX_TOUCHES ? count : MAX_TOUCHES;
    for (int i = 0; i < n; i++) {
        xs[i] = touches[i].normalized.position.x;
        ys[i] = touches[i].normalized.position.y;
    }
    gHandler(n, xs, ys, timestamp);
    return 0;
}

int mtb_start(MTBFrameHandler handler) {
    if (gDevices) return (int)CFArrayGetCount(gDevices);
    void *lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!lib) return -1;
    pMTDeviceCreateList = dlsym(lib, "MTDeviceCreateList");
    pMTRegisterContactFrameCallback = dlsym(lib, "MTRegisterContactFrameCallback");
    pMTUnregisterContactFrameCallback = dlsym(lib, "MTUnregisterContactFrameCallback");
    pMTDeviceStart = dlsym(lib, "MTDeviceStart");
    pMTDeviceStop = dlsym(lib, "MTDeviceStop");
    if (!pMTDeviceCreateList || !pMTRegisterContactFrameCallback || !pMTDeviceStart) return -1;

    gHandler = handler;
    gDevices = pMTDeviceCreateList();
    if (!gDevices) return 0;
    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        pMTRegisterContactFrameCallback(device, contactCallback);
        pMTDeviceStart(device, 0);
    }
    return (int)count;
}

void mtb_stop(void) {
    if (!gDevices) return;
    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        if (pMTUnregisterContactFrameCallback) pMTUnregisterContactFrameCallback(device, contactCallback);
        if (pMTDeviceStop) pMTDeviceStop(device);
    }
    CFRelease(gDevices);
    gDevices = NULL;
    gHandler = NULL;
}

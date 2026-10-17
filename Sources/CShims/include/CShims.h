#ifndef CSHIMS_H
#define CSHIMS_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

// ---- MultitouchSupport.framework (private) ----
// Layout matches the MTTouch struct used by MultitouchSupport on macOS 10.x – 27.

typedef struct { float x; float y; } MTPoint;
typedef struct { MTPoint position; MTPoint velocity; } MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;   // stable id for one finger while it stays on the surface
    int32_t state;       // 1 start-in-range, 2 hover, 3 make-touch, 4 touching, 5 break-touch, 6 linger, 7 out-of-range
    int32_t fingerID;
    int32_t handID;
    MTVector normalized; // 0...1, origin bottom-left
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;   // millimetres
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTTouch;

typedef const void *MTDeviceRef;
typedef int32_t (*CMTContactCallback)(MTDeviceRef device, const MTTouch *touches, int32_t numTouches, double timestamp, int32_t frame);
/// Called when the device's physical button state changes (the Siri Remote's clickpad click).
typedef void (*CMTButtonStateCallback)(MTDeviceRef device, uint32_t newState, uint32_t oldState, void *refcon);

/// Loads MultitouchSupport and resolves its symbols. Safe to call repeatedly.
bool CMTLoad(void);
/// Human readable reason when CMTLoad() failed.
const char *CMTLoadError(void);

CFArrayRef CMTDeviceCreateList(void);
MTDeviceRef CMTDeviceCreateFromService(io_service_t service);
bool CMTDeviceGetFamilyID(MTDeviceRef device, int32_t *familyID);
void CMTRegisterContactFrameCallback(MTDeviceRef device, CMTContactCallback callback);
void CMTUnregisterContactFrameCallback(MTDeviceRef device, CMTContactCallback callback);
bool CMTRegisterButtonStateCallback(MTDeviceRef device, CMTButtonStateCallback callback, void *refcon);
void CMTUnregisterButtonStateCallback(MTDeviceRef device, CMTButtonStateCallback callback);
int32_t CMTDeviceStart(MTDeviceRef device, int32_t mode);
int32_t CMTDeviceStop(MTDeviceRef device);
bool CMTDeviceIsRunning(MTDeviceRef device);
void CMTDeviceRelease(MTDeviceRef device);

// ---- libproc ----
/// Writes the short process name for pid into buffer. Returns the length, or 0 on failure.
int CShimProcName(pid_t pid, char *buffer, uint32_t size);
/// Fills pids with all process ids. Returns the count written.
int CShimListPids(pid_t *pids, int capacity);
/// Short command name and owning uid via sysctl. Works for other users' processes. Returns false if pid is gone.
bool CShimProcInfo(pid_t pid, char *name, uint32_t size, uid_t *uid);

#endif

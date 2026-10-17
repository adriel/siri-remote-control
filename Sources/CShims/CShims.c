#include "CShims.h"
#include <dlfcn.h>
#include <libproc.h>
#include <string.h>
#include <sys/sysctl.h>

typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef MTDeviceRef (*MTDeviceCreateFromServiceFn)(io_service_t);
typedef int32_t (*MTDeviceGetFamilyIDFn)(MTDeviceRef, int32_t *);
typedef void (*MTRegisterFn)(MTDeviceRef, CMTContactCallback);
typedef int32_t (*MTDeviceStartFn)(MTDeviceRef, int32_t);
typedef int32_t (*MTDeviceStopFn)(MTDeviceRef);
typedef bool (*MTDeviceIsRunningFn)(MTDeviceRef);
typedef void (*MTDeviceReleaseFn)(MTDeviceRef);
typedef int32_t (*MTRegisterButtonFn)(MTDeviceRef, CMTButtonStateCallback, void *);
typedef int32_t (*MTUnregisterButtonFn)(MTDeviceRef, CMTButtonStateCallback);

static void *gHandle;
static const char *gError = "not loaded";
static MTDeviceCreateListFn pCreateList;
static MTDeviceCreateFromServiceFn pCreateFromService;
static MTDeviceGetFamilyIDFn pGetFamilyID;
static MTRegisterFn pRegister;
static MTRegisterFn pUnregister;
static MTDeviceStartFn pStart;
static MTDeviceStopFn pStop;
static MTDeviceIsRunningFn pIsRunning;
static MTDeviceReleaseFn pRelease;
static MTRegisterButtonFn pRegisterButton;
static MTUnregisterButtonFn pUnregisterButton;

bool CMTLoad(void) {
    if (gHandle) return pRegister != NULL && pStart != NULL;
    gHandle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!gHandle) { gError = "dlopen(MultitouchSupport) failed"; return false; }
    pCreateList = (MTDeviceCreateListFn)dlsym(gHandle, "MTDeviceCreateList");
    pCreateFromService = (MTDeviceCreateFromServiceFn)dlsym(gHandle, "MTDeviceCreateFromService");
    pGetFamilyID = (MTDeviceGetFamilyIDFn)dlsym(gHandle, "MTDeviceGetFamilyID");
    pRegister = (MTRegisterFn)dlsym(gHandle, "MTRegisterContactFrameCallback");
    pUnregister = (MTRegisterFn)dlsym(gHandle, "MTUnregisterContactFrameCallback");
    pStart = (MTDeviceStartFn)dlsym(gHandle, "MTDeviceStart");
    pStop = (MTDeviceStopFn)dlsym(gHandle, "MTDeviceStop");
    pIsRunning = (MTDeviceIsRunningFn)dlsym(gHandle, "MTDeviceIsRunning");
    pRelease = (MTDeviceReleaseFn)dlsym(gHandle, "MTDeviceRelease");
    pRegisterButton = (MTRegisterButtonFn)dlsym(gHandle, "MTRegisterButtonStateCallback");
    pUnregisterButton = (MTUnregisterButtonFn)dlsym(gHandle, "MTUnregisterButtonStateCallback");
    if (!pRegister || !pStart) { gError = "MultitouchSupport symbols missing"; return false; }
    gError = "";
    return true;
}

const char *CMTLoadError(void) { return gError; }

CFArrayRef CMTDeviceCreateList(void) { return pCreateList ? pCreateList() : NULL; }
MTDeviceRef CMTDeviceCreateFromService(io_service_t service) { return pCreateFromService ? pCreateFromService(service) : NULL; }

bool CMTDeviceGetFamilyID(MTDeviceRef device, int32_t *familyID) {
    if (!pGetFamilyID) return false;
    return pGetFamilyID(device, familyID) == 0;
}

void CMTRegisterContactFrameCallback(MTDeviceRef device, CMTContactCallback callback) { if (pRegister) pRegister(device, callback); }
void CMTUnregisterContactFrameCallback(MTDeviceRef device, CMTContactCallback callback) { if (pUnregister) pUnregister(device, callback); }
bool CMTRegisterButtonStateCallback(MTDeviceRef device, CMTButtonStateCallback callback, void *refcon) {
    return pRegisterButton ? pRegisterButton(device, callback, refcon) != 0 : false;
}
void CMTUnregisterButtonStateCallback(MTDeviceRef device, CMTButtonStateCallback callback) {
    if (pUnregisterButton) pUnregisterButton(device, callback);
}
int32_t CMTDeviceStart(MTDeviceRef device, int32_t mode) { return pStart ? pStart(device, mode) : -1; }
int32_t CMTDeviceStop(MTDeviceRef device) { return pStop ? pStop(device) : -1; }
bool CMTDeviceIsRunning(MTDeviceRef device) { return pIsRunning ? pIsRunning(device) : false; }

void CMTDeviceRelease(MTDeviceRef device) {
    if (pRelease) pRelease(device);
    else CFRelease(device);
}

int CShimProcName(pid_t pid, char *buffer, uint32_t size) { return proc_name(pid, buffer, size); }

int CShimListPids(pid_t *pids, int capacity) {
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    return count < 0 ? 0 : count;
}

bool CShimProcInfo(pid_t pid, char *name, uint32_t size, uid_t *uid) {
    struct kinfo_proc info;
    size_t length = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0 || length == 0) return false;
    if (name && size > 0) {
        strncpy(name, info.kp_proc.p_comm, size - 1);
        name[size - 1] = 0;
    }
    if (uid) *uid = info.kp_eproc.e_ucred.cr_uid;
    return true;
}

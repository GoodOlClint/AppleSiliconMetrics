// Prototypes for Apple's private `IOReport` framework.
//
// These are NOT from any Apple header (there is no public one) and were
// reconstructed from the documented-by-reverse-engineering call sequence used
// by the MIT-licensed `macmon`, `mactop`, and `agtop` projects. No GPL sources
// were consulted. Signatures are best-effort; every call site degrades to `nil`
// rather than trapping, because these interfaces are undocumented and may
// change between macOS releases.
#ifndef CIOREPORT_H
#define CIOREPORT_H

#include <CoreFoundation/CoreFoundation.h>

// Opaque subscription handle returned by IOReportCreateSubscription. Declared
// as a plain opaque pointer (not a CF type) so Swift imports it as an
// OpaquePointer we manage by hand rather than via ARC.
typedef struct __IOReportSubscription *IOReportSubscriptionRef;

// --- not CF-audited: handled explicitly in Swift -------------------------

// Creates a subscription for `desiredChannels`; writes the actually-subscribed
// channel set into `*subbedChannels` (caller owns it, +1). Pass NULL/0 for the
// remaining arguments.
IOReportSubscriptionRef IOReportCreateSubscription(
    void *a, CFDictionaryRef desiredChannels,
    CFMutableDictionaryRef *subbedChannels, uint64_t channelCount, CFTypeRef b);

// Merge `b`'s channels into `a` (used when combining groups). Returns void.
void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef nilp);

// --- CF-audited region: Copy/Create return +1 (ARC-managed in Swift), -----
// --- everything else returns +0 and bridges directly. ---------------------
CF_IMPLICIT_BRIDGING_ENABLED

// Copy the channels in a group (and optional subgroup). Pass NULL subgroup to
// take the whole group. Trailing args are 0.
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group,
                                            CFStringRef subgroup, uint64_t a,
                                            uint64_t b, uint64_t c);

// Copy every channel the system exposes, across all groups. Used only for
// discovery (ASMETRICS_DEBUG) — sampling always subscribes to named groups.
// Both args are 0.
CFDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);

// Snapshot the current counter values for the subscribed channels.
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef subscription,
                                      CFMutableDictionaryRef subbedChannels,
                                      CFTypeRef b);

// Element-wise delta of two samples (later minus earlier).
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef earlier,
                                           CFDictionaryRef later, CFTypeRef b);

// Per-channel accessors. `channel` is one element of the "IOReportChannels"
// array inside a sample/delta dictionary.
CFStringRef IOReportChannelGetGroup(CFDictionaryRef channel);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef channel);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);

// Simple (scalar) channel value, e.g. an energy counter. `b` is 0.
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t b);

// State (residency-table) channel accessors.
int32_t IOReportStateGetCount(CFDictionaryRef channel);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef channel, int32_t index);
int64_t IOReportStateGetResidency(CFDictionaryRef channel, int32_t index);

CF_IMPLICIT_BRIDGING_DISABLED

// --- AppleSMC user-client (temperature fallback) -------------------------
//
// Where IOReport does not expose a GPU/SoC die temperature (e.g. M5, which
// dropped the "GPU Stats"/"Temperature" channels that M4 has), we read the SMC
// sensor keys directly. This struct + selector are the long-standing
// smcFanControl / macmon / mactop layout (MIT lineage, no GPL). Reading sensor
// keys is UNPRIVILEGED — only SMC *writes* (fan control) need root.
//
// One selector, kSMCHandleYPCEvent, services three commands distinguished by
// the request's `data8`: read a key's value (kSMCReadKey), read its type/size
// (kSMCGetKeyInfo), or map an index to a key code (kSMCGetKeyFromIndex, used to
// enumerate every key via the "#KEY" count).
enum { kSMCHandleYPCEvent = 2 };
enum { kSMCReadKey = 5, kSMCGetKeyInfo = 9, kSMCGetKeyFromIndex = 8 };

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;  // 4-char code as a big-endian UInt32, e.g. 'flt '
    uint8_t dataAttributes;
} SMCKeyInfoData;

// Request/response struct passed to IOConnectCallStructMethod. C computes the
// field offsets so Swift imports it with an exactly-matching layout.
typedef struct {
    uint32_t key;  // 4-char key code as a big-endian UInt32
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

#endif /* CIOREPORT_H */

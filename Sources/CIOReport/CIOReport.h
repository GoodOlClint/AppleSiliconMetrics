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

#endif /* CIOREPORT_H */

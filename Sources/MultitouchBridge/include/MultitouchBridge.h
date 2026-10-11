#ifndef MULTITOUCH_BRIDGE_H
#define MULTITOUCH_BRIDGE_H

/// Called on the multitouch thread for every trackpad frame.
/// xs/ys are normalized (0...1) finger positions, `count` entries long.
typedef void (*MTBFrameHandler)(int count, const float *xs, const float *ys, double timestamp);

/// Loads the private MultitouchSupport framework and starts listening to every trackpad.
/// Returns the number of devices started, or -1 if the framework could not be loaded.
int mtb_start(MTBFrameHandler handler);

/// Stops listening.
void mtb_stop(void);

#endif

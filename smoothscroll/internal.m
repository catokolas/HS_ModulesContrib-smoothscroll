// hs._ckol.smoothscroll.internal — continuous-scroll CGEvent poster
//
// Posts NSEventTypeScrollWheel events (type 22) with `IsContinuous=1`
// from a CVDisplayLink callback. No per-event gesture/momentum phase
// markers and no companion gesture event — the receiving app sees a
// stream of continuous scroll events with smoothly decreasing deltas
// during the momentum tail, exactly like what a trackpad's continuous-
// scroll output looks like to ordinary AppKit / WebKit / Chromium
// scroll views.
//
// Architecture:
//
//   IDLE  → (tick) → ACTIVE  → (buf drained + gap) → MOMENTUM → IDLE
//
//   ACTIVE: drain the per-tick wheel buffer at `buf/msPerStep` px/ms.
//           Each animator frame's raw px is fed through a biased point-
//           delta sub-pixelator (per axis); we only post when the
//           accumulator crosses an integer. First emit per gesture is
//           biased up to ±1 so a slow click still produces one event.
//   MOMENTUM: drive a DragCurve (b=1 exponential or b=2 v² decay) from
//           the exit velocity captured when the buffer drained. Same
//           subpixelator gates emission. When velocity drops below
//           `stopSpeed`, idle.
//
// Concurrency:
// - Lua thread mutates state under stateMutex (configure / tick / cancel /
//   stop).
// - Display-link callback reads + updates state under stateMutex, then
//   posts CGEvents OUTSIDE the lock (CGEventPost is documented
//   thread-safe).

@import Cocoa;
@import CoreVideo;
@import LuaSkin;

#include <pthread.h>
#include <math.h>
#include <string.h>

#pragma mark - Constants

/// CGEvent field numbers used on the type-22 scroll wheel event.
/// Most have named constants in CGEventTypes.h; `kField_Type` is the
/// reverse-engineered equivalent of CGEventSetType().
enum {
    kField_Type                  = 55,
    kField_IsContinuous          = 88,   // kCGScrollWheelEventIsContinuous
    kField_DirectionInverted     = 137,  // NSEvent.directionInvertedFromDevice
    kField_DeltaAxis1            = 11,
    kField_DeltaAxis2            = 12,
    kField_PointDeltaAxis1       = 96,
    kField_PointDeltaAxis2       = 97,
    kField_FixedPtDeltaAxis1     = 93,
    kField_FixedPtDeltaAxis2     = 94,
    kField_UserData              = 42,   // kCGEventSourceUserData
};

enum { kCGEventType_ScrollWheel = 22 };

#pragma mark - Tunable parameters (mirror Lua-side configure)

typedef struct {
    /// Input shaping
    double pxStepSize;          // base px per wheel tick
    double acceleration;        // per-tick multiplier within burst
    double tickGapS;            // burst boundary
    double swipeGapS;
    int    swipeTickThresh;
    int    fastSwipeThresh;
    double fastFactor;
    double fastBase;
    /// Buffer drain
    double msPerStep;           // duration to drain buf at constant rate
    /// Active-to-momentum transition
    double gestureEndGapMs;     // ms since last tick before momentum starts
    /// Momentum (DragCurve)
    double dragCoefficient;     // a in v'(t) = -a·v^b
    double dragExponent;        // b — 1.0 (exponential) or 2.0 (v² decay)
    double stopSpeedPxMs;       // px/ms — momentum cutoff
    /// Output composition
    double linePx;              // px per line for kField_DeltaAxis
    int    invertedFromDevice;  // 0 or 1
    int64_t sentinel;           // stamped on kField_UserData
} Params;

static Params params = {
    .pxStepSize       = 36.0,
    .acceleration     = 1.75,
    .tickGapS         = 0.13,
    .swipeGapS        = 0.35,
    .swipeTickThresh  = 2,
    .fastSwipeThresh  = 3,
    .fastFactor       = 1.1,
    .fastBase         = 1.1,
    .msPerStep        = 90.0,
    .gestureEndGapMs  = 80.0,
    // Exponential decay (b=1) by default. Receivers consume our momentum
    // deltas directly; v'(t) = -a·v with small a gives the long shallow
    // tail. (b=2's `v²` shape starts steeper at typical exit velocities
    // and feels abrupt at the active-to-momentum transition.)
    .dragCoefficient  = 0.010,   // 1/ms — half-life ≈ 69 ms
    .dragExponent     = 1.0,
    .stopSpeedPxMs    = 0.03,    // 30 px/s
    .linePx           = 10.0,
    .invertedFromDevice = 0,
    .sentinel         = 0xC0DE5C01,
};

#pragma mark - State

typedef enum {
    PHASE_IDLE     = 0,
    PHASE_ACTIVE   = 1,   // draining wheel-tick buffer
    PHASE_MOMENTUM = 2,   // DragCurve momentum tail
} EnginePhase;

typedef struct {
    double buf;              // pending px (signed)
    double msLeft;           // ms remaining to drain buf
    double exitVel;          // px/ms captured at buf drain (sign = direction)
    double momentumAgeMs;    // time since momentum began
    double momentumDistEmitted;  // accumulated momentum-phase distance
    double pointAccum;       // fractional point-delta accumulator with biased
                             // first-emit semantics — see drainPointBiased.
                             // Events are only posted when the integer point
                             // delta crosses ±1, so a 1-px slow click
                             // produces exactly one event instead of one
                             // per animator frame.
    int    firstEmitDone;    // tracks whether the biased first-emit has
                             // fired for the current active gesture. Reset
                             // on each fresh PHASE_ACTIVE transition.
    int    lastDir;          // ±1, 0
} Axis;

typedef struct {
    int    tickCount;
    int    swipeCount;
    double lastTickS;
    double lastSwipeEndS;
} Burst;

static Axis axisX = {0};
static Axis axisY = {0};
static Burst burst = {0};
static EnginePhase engPhase = PHASE_IDLE;
static double lastFrameHostSecs = 0.0;

static CVDisplayLinkRef displayLink = NULL;
static pthread_mutex_t   stateMutex = PTHREAD_MUTEX_INITIALIZER;

#pragma mark - Math helpers

static double nowSecs(void) { return (double)CFAbsoluteTimeGetCurrent(); }

static int sgn(double v) { return (v > 0) - (v < 0); }

static double signedFloor(double v) { return (v >= 0) ? floor(v) : ceil(v); }
static double signedCeil (double v) { return (v >= 0) ? ceil(v)  : floor(v); }

/// 16.16 fixed-point packing for FixedPtDelta fields.
static int64_t fixedScrollDelta(double v) {
    return (int64_t)round(v * 65536.0);
}

/// Biased sub-pixelator for point delta. Adds rawPx to the per-axis
/// accumulator and returns the integer point delta to emit:
///
///  - First emit of a gesture (in `gestureDir`): rounds *up* to ±1
///    even if accumulated < 1. So a tiny slow click (e.g. 0.185 px
///    accumulated after the first frame) still emits one event with
///    point delta ±1, while leaving a debt of ~0.815 in the
///    accumulator. Subsequent frames erode the debt; no further emit
///    fires until accum crosses ±1 again.
///  - Subsequent emits use signed floor (normal sub-pixel drain).
///
/// This gives "one event per slow click" behaviour in terminals
/// instead of one-event-per-animator-frame.
static int64_t drainPointBiased(Axis *axis, double rawPx, int gestureDir) {
    axis->pointAccum += rawPx;

    // If accum sign is opposite to gesture direction, we're in debt
    // (after a biased first-emit) — never emit in the wrong direction.
    if (gestureDir > 0 && axis->pointAccum <= 0) return 0;
    if (gestureDir < 0 && axis->pointAccum >= 0) return 0;

    if (fabs(axis->pointAccum) >= 1.0) {
        double whole = (axis->pointAccum > 0) ? floor(axis->pointAccum)
                                              : ceil(axis->pointAccum);
        axis->pointAccum -= whole;
        axis->firstEmitDone = 1;
        return (int64_t)whole;
    }

    if (!axis->firstEmitDone) {
        int64_t emit = (int64_t)gestureDir;   // ±1 in the gesture direction
        axis->pointAccum -= (double)emit;
        axis->firstEmitDone = 1;
        return emit;
    }

    return 0;
}

/// Biased line-delta rounding (post-drain): for a non-zero point delta,
/// emit at least ±1 line if |lineFloat| ≤ 1, else floor. Ensures any
/// non-zero gesture produces at least one row of scroll in apps that
/// honour line deltas (Finder list, NSTableView).
static int64_t lineIntBiased(double lineDelta) {
    if (lineDelta == 0.0) return 0;
    if (fabs(lineDelta) <= 1.0) return (int64_t)signedCeil(lineDelta);
    return (int64_t)signedFloor(lineDelta);
}

#pragma mark - DragCurve (general b, with closed-form b=1 / b=2 paths)

/// Solves v'(t) = -a · v^b analytically.
///
/// General case (b ≠ 1 and b ≠ 2):
///   v(t)          = (v0^(1-b) − (1-b)·a·t)^(1/(1-b))    while v(t) > 0
///   distance(t)   = (v0^(2-b) − v(t)^(2-b)) / ((2-b)·a)
///   duration(v0→vStop) = (v0^(1-b) − vStop^(1-b)) / ((1-b)·a)
///
/// Closed forms for b=1 (exponential decay) and b=2 (v² decay) are kept
/// as fast paths because they're the two values most engines pick.
///
/// b=0.7 (between line and exponential) decays *slower* at high velocity
/// and *faster* at low velocity than b=1 — the "coast at speed, snap to
/// stop" trackpad-like feel.
static double dragDistanceAt(double t, double v0, double a, double b) {
    if (v0 <= 0 || t <= 0) return 0;
    if (b == 1.0) return (v0 / a) * (1.0 - exp(-a * t));
    if (b == 2.0) return (1.0 / a) * log(1.0 + a * v0 * t);
    double oneMinusB = 1.0 - b;
    double twoMinusB = 2.0 - b;
    double v0_pow1mb = pow(v0, oneMinusB);
    double u = v0_pow1mb - oneMinusB * a * t;
    double v_t = (u > 0.0) ? pow(u, 1.0 / oneMinusB) : 0.0;
    return (pow(v0, twoMinusB) - pow(v_t, twoMinusB)) / (twoMinusB * a);
}

static double dragDurationFor(double v0, double vStop, double a, double b) {
    if (v0 <= vStop) return 0;
    if (b == 1.0) return log(v0 / vStop) / a;
    if (b == 2.0) return (1.0 / vStop - 1.0 / v0) / a;
    double oneMinusB = 1.0 - b;
    return (pow(v0, oneMinusB) - pow(vStop, oneMinusB)) / (oneMinusB * a);
}

#pragma mark - Burst counter (call under stateMutex)

static void updateBurst(double now) {
    if (now - burst.lastTickS > params.tickGapS) {
        if (burst.tickCount >= params.swipeTickThresh) {
            if (now - burst.lastSwipeEndS > params.swipeGapS) {
                burst.swipeCount = 1;
            } else {
                burst.swipeCount += 1;
            }
            burst.lastSwipeEndS = burst.lastTickS;
        } else if (now - burst.lastSwipeEndS > params.swipeGapS) {
            burst.swipeCount = 0;
        }
        burst.tickCount = 1;
    } else {
        burst.tickCount += 1;
    }
    burst.lastTickS = now;
}

#pragma mark - Per-axis enqueue (call under stateMutex)

static void enqueueAxis(Axis *axis, int dir) {
    if (dir == 0) return;
    if (axis->lastDir != 0 && axis->lastDir != dir) {
        // Direction reversal: clear in-flight buf and momentum-tail debt.
        axis->buf            = 0;
        axis->msLeft         = 0;
        axis->exitVel        = 0;
        axis->pointAccum     = 0;
        axis->firstEmitDone  = 0;
        axis->lastDir        = 0;
    }
    axis->buf += (double)dir * params.pxStepSize;
    // Compounding burst acceleration: multiply the whole buffer (not just
    // the new addition) so consecutive ticks within a burst stack — same
    // semantics as the Spoon's default engine.
    if (burst.tickCount > 1) {
        axis->buf *= params.acceleration;
    }
    int fastDelta = burst.swipeCount - params.fastSwipeThresh;
    if (fastDelta >= 0) {
        axis->buf *= params.fastFactor * pow(params.fastBase, (double)fastDelta);
    }
    axis->msLeft = params.msPerStep;
    axis->lastDir = dir;
}

#pragma mark - Per-axis frame advance during active phase

/// Returns the raw px delta for this frame (signed, fractional). Drains
/// the buffer over `msLeft` and captures `exitVel` when the buffer
/// finishes — used as v0 for the upcoming momentum DragCurve.
static double advanceAxis_Active(Axis *axis, double dtMs) {
    if (axis->buf == 0.0 || axis->msLeft <= 0.0) {
        return 0.0;
    }
    double rawPx = (axis->buf / axis->msLeft) * dtMs;
    axis->buf    -= rawPx;
    axis->msLeft -= dtMs;
    if (fabs(axis->buf) < 0.5 || axis->msLeft <= 0) {
        axis->exitVel = (dtMs > 0) ? (rawPx / dtMs) : 0.0;
        axis->buf     = 0;
        axis->msLeft  = 0;
    }
    return rawPx;
}

#pragma mark - CGEvent posting

/// Post one continuous-scroll event with the given integer point and line
/// deltas (per axis). No phase markers — the stream is treated as one
/// logical scroll by the receiver, which keeps terminals from counting
/// each animator frame as a separate wheel input.
static void postContinuousFrame(double dxPoint, double dyPoint,
                                int64_t dxLineInt, int64_t dyLineInt) {
    CGEventRef ev = CGEventCreate(NULL);
    CGEventSetIntegerValueField(ev, (CGEventField)kField_Type, kCGEventType_ScrollWheel);
    CGEventSetIntegerValueField(ev, (CGEventField)kField_IsContinuous, 1);
    CGEventSetIntegerValueField(ev, (CGEventField)kField_DirectionInverted, params.invertedFromDevice);

    double dxLine = dxPoint / params.linePx;
    double dyLine = dyPoint / params.linePx;

    CGEventSetIntegerValueField(ev, (CGEventField)kField_DeltaAxis1, dyLineInt);
    CGEventSetIntegerValueField(ev, (CGEventField)kField_PointDeltaAxis1, (int64_t)round(dyPoint));
    CGEventSetIntegerValueField(ev, (CGEventField)kField_FixedPtDeltaAxis1, fixedScrollDelta(dyLine));

    CGEventSetIntegerValueField(ev, (CGEventField)kField_DeltaAxis2, dxLineInt);
    CGEventSetIntegerValueField(ev, (CGEventField)kField_PointDeltaAxis2, (int64_t)round(dxPoint));
    CGEventSetIntegerValueField(ev, (CGEventField)kField_FixedPtDeltaAxis2, fixedScrollDelta(dxLine));

    CGEventSetIntegerValueField(ev, (CGEventField)kField_UserData, params.sentinel);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
}

#pragma mark - Display-link callback

static CVReturn displayLinkCallback(
        CVDisplayLinkRef link,
        const CVTimeStamp *inNow,
        const CVTimeStamp *inOutputTime,
        CVOptionFlags flagsIn,
        CVOptionFlags *flagsOut,
        void *displayLinkContext) {
    (void)inNow; (void)inOutputTime; (void)flagsIn; (void)flagsOut;
    (void)displayLinkContext;

    double now = nowSecs();
    double dtMs;
    if (lastFrameHostSecs == 0.0) {
        dtMs = 1000.0 / 120.0;
    } else {
        dtMs = (now - lastFrameHostSecs) * 1000.0;
        if (dtMs < 1.0)  dtMs = 1.0;
        if (dtMs > 50.0) dtMs = 50.0;
    }
    lastFrameHostSecs = now;

    // Snapshot the per-frame output, drop the lock, post outside.
    BOOL    havePost  = NO;
    double  dxOut     = 0.0, dyOut = 0.0;
    int64_t dxLineOut = 0, dyLineOut = 0;

    pthread_mutex_lock(&stateMutex);

    if (engPhase == PHASE_ACTIVE) {
        double rawDx = advanceAxis_Active(&axisX, dtMs);
        double rawDy = advanceAxis_Active(&axisY, dtMs);

        BOOL bufEmpty = (axisX.buf == 0 && axisY.buf == 0);
        double gapMs = (now - burst.lastTickS) * 1000.0;
        BOOL gapSatisfied = (gapMs >= params.gestureEndGapMs);

        if (bufEmpty && gapSatisfied) {
            double vx = axisX.exitVel;
            double vy = axisY.exitVel;
            double speed = sqrt(vx*vx + vy*vy);
            if (speed > params.stopSpeedPxMs) {
                engPhase = PHASE_MOMENTUM;
                axisX.momentumAgeMs = 0;
                axisY.momentumAgeMs = 0;
                axisX.momentumDistEmitted = 0;
                axisY.momentumDistEmitted = 0;
            } else {
                engPhase = PHASE_IDLE;
                axisX.exitVel = 0;       axisY.exitVel = 0;
                axisX.lastDir = 0;       axisY.lastDir = 0;
            }
        } else if (rawDx != 0 || rawDy != 0) {
            // Mid-active frame: subpixelate per axis. Skip the post if
            // neither axis crossed an integer — terminals (which count
            // one scroll line per event) otherwise over-emit.
            int gxDir = (rawDx > 0) - (rawDx < 0);
            int gyDir = (rawDy > 0) - (rawDy < 0);
            int64_t pxX = drainPointBiased(&axisX, rawDx, gxDir);
            int64_t pxY = drainPointBiased(&axisY, rawDy, gyDir);
            if (pxX != 0 || pxY != 0) {
                havePost  = YES;
                dxOut     = (double)pxX;
                dyOut     = (double)pxY;
                dxLineOut = lineIntBiased((double)pxX / params.linePx);
                dyLineOut = lineIntBiased((double)pxY / params.linePx);
            }
        }
    } else if (engPhase == PHASE_MOMENTUM) {
        // Drive DragCurve per axis. Each axis decays independently from
        // its own exitVel; we track emitted distance and emit the diff-
        // of-distance each frame (so cumulative emission matches the
        // closed-form curve, no Euler-integration drift).
        double a = params.dragCoefficient;
        double b = params.dragExponent;
        double vStop = params.stopSpeedPxMs;

        double new_dx = 0, new_dy = 0;

        if (axisX.exitVel != 0.0) {
            double v0  = fabs(axisX.exitVel);
            int    dir = sgn(axisX.exitVel);
            axisX.momentumAgeMs += dtMs;
            double dur = dragDurationFor(v0, vStop, a, b);
            double t   = (axisX.momentumAgeMs > dur) ? dur : axisX.momentumAgeMs;
            double totalDist = dragDistanceAt(t, v0, a, b);
            new_dx = (totalDist - axisX.momentumDistEmitted) * (double)dir;
            axisX.momentumDistEmitted = totalDist;
            if (axisX.momentumAgeMs >= dur) axisX.exitVel = 0.0;
        }
        if (axisY.exitVel != 0.0) {
            double v0  = fabs(axisY.exitVel);
            int    dir = sgn(axisY.exitVel);
            axisY.momentumAgeMs += dtMs;
            double dur = dragDurationFor(v0, vStop, a, b);
            double t   = (axisY.momentumAgeMs > dur) ? dur : axisY.momentumAgeMs;
            double totalDist = dragDistanceAt(t, v0, a, b);
            new_dy = (totalDist - axisY.momentumDistEmitted) * (double)dir;
            axisY.momentumDistEmitted = totalDist;
            if (axisY.momentumAgeMs >= dur) axisY.exitVel = 0.0;
        }

        BOOL bothExhausted = (axisX.exitVel == 0.0 && axisY.exitVel == 0.0);

        if (bothExhausted) {
            engPhase = PHASE_IDLE;
            axisX.lastDir = 0;             axisY.lastDir = 0;
            axisX.momentumDistEmitted = 0; axisY.momentumDistEmitted = 0;
            axisX.pointAccum = 0;          axisY.pointAccum = 0;
            axisX.firstEmitDone = 0;       axisY.firstEmitDone = 0;
        } else if (new_dx != 0 || new_dy != 0) {
            int gxDir = (new_dx > 0) - (new_dx < 0);
            int gyDir = (new_dy > 0) - (new_dy < 0);
            int64_t pxX = drainPointBiased(&axisX, new_dx, gxDir);
            int64_t pxY = drainPointBiased(&axisY, new_dy, gyDir);
            if (pxX != 0 || pxY != 0) {
                havePost  = YES;
                dxOut     = (double)pxX;
                dyOut     = (double)pxY;
                dxLineOut = lineIntBiased((double)pxX / params.linePx);
                dyLineOut = lineIntBiased((double)pxY / params.linePx);
            }
        }
    }

    BOOL stopLink = (engPhase == PHASE_IDLE);
    pthread_mutex_unlock(&stateMutex);

    if (havePost) {
        postContinuousFrame(dxOut, dyOut, dxLineOut, dyLineOut);
    }

    if (stopLink && link) {
        CVDisplayLinkStop(link);
        lastFrameHostSecs = 0.0;
    }
    return kCVReturnSuccess;
}

#pragma mark - Display-link lifecycle (Lua thread)

static BOOL ensureDisplayLink(void) {
    if (displayLink) return YES;
    CVReturn rc = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    if (rc != kCVReturnSuccess || !displayLink) {
        displayLink = NULL;
        return NO;
    }
    CVDisplayLinkSetOutputCallback(displayLink, &displayLinkCallback, NULL);
    return YES;
}

static void startDisplayLinkIfNeeded(void) {
    if (!ensureDisplayLink()) return;
    if (!CVDisplayLinkIsRunning(displayLink)) {
        lastFrameHostSecs = 0.0;
        CVDisplayLinkStart(displayLink);
    }
}

static void stopDisplayLink(void) {
    if (displayLink && CVDisplayLinkIsRunning(displayLink)) {
        CVDisplayLinkStop(displayLink);
    }
    lastFrameHostSecs = 0.0;
}

#pragma mark - Lua API

#define READ_OPT_NUM(key, dst) do { \
    lua_getfield(L, 1, key); \
    if (lua_type(L, -1) == LUA_TNUMBER) dst = lua_tonumber(L, -1); \
    lua_pop(L, 1); \
} while (0)

#define READ_OPT_INT(key, dst) do { \
    lua_getfield(L, 1, key); \
    if (lua_type(L, -1) == LUA_TNUMBER) dst = (int)lua_tointeger(L, -1); \
    lua_pop(L, 1); \
} while (0)

#define READ_OPT_I64(key, dst) do { \
    lua_getfield(L, 1, key); \
    if (lua_type(L, -1) == LUA_TNUMBER) dst = (int64_t)lua_tointeger(L, -1); \
    lua_pop(L, 1); \
} while (0)

/// hs._ckol.smoothscroll.configure(params) -> nil
/// Function
/// Update tuning parameters. See README for keys.
static int l_configure(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TTABLE, LS_TBREAK];

    pthread_mutex_lock(&stateMutex);
    READ_OPT_NUM("pxStepSize",         params.pxStepSize);
    READ_OPT_NUM("acceleration",       params.acceleration);
    READ_OPT_NUM("tickGap",            params.tickGapS);
    READ_OPT_NUM("swipeGap",           params.swipeGapS);
    READ_OPT_INT("swipeTickThresh",    params.swipeTickThresh);
    READ_OPT_INT("fastSwipeThresh",    params.fastSwipeThresh);
    READ_OPT_NUM("fastFactor",         params.fastFactor);
    READ_OPT_NUM("fastBase",           params.fastBase);
    READ_OPT_NUM("msPerStep",          params.msPerStep);
    READ_OPT_NUM("gestureEndGapMs",    params.gestureEndGapMs);
    READ_OPT_NUM("dragCoefficient",    params.dragCoefficient);
    READ_OPT_NUM("dragExponent",       params.dragExponent);
    READ_OPT_NUM("stopSpeed",          params.stopSpeedPxMs);
    READ_OPT_NUM("linePx",             params.linePx);
    READ_OPT_INT("invertedFromDevice", params.invertedFromDevice);
    READ_OPT_I64("sentinel",           params.sentinel);
    pthread_mutex_unlock(&stateMutex);
    return 0;
}

/// hs._ckol.smoothscroll.tick(dirX, dirY) -> nil
/// Function
/// Enqueue one wheel tick. dirX/dirY are -1, 0, or 1.
static int l_tick(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TNUMBER, LS_TNUMBER, LS_TBREAK];
    int dirX = (int)lua_tointeger(L, 1);
    int dirY = (int)lua_tointeger(L, 2);

    pthread_mutex_lock(&stateMutex);
    double now = nowSecs();
    updateBurst(now);
    // If a momentum tail is still running, pre-empt it (treat new tick as
    // a fresh ACTIVE phase). The stream is continuous from the receiver's
    // point of view either way — no transition event needed.
    if (engPhase != PHASE_ACTIVE) {
        engPhase = PHASE_ACTIVE;
        axisX.momentumAgeMs = 0;
        axisY.momentumAgeMs = 0;
        axisX.momentumDistEmitted = 0;
        axisY.momentumDistEmitted = 0;
        // Reset biased-emit flag so the first frame of the new gesture
        // can emit ±1 even if accumulated point delta is fractional.
        axisX.firstEmitDone = 0;
        axisY.firstEmitDone = 0;
        axisX.pointAccum = 0;
        axisY.pointAccum = 0;
    }
    enqueueAxis(&axisX, dirX);
    enqueueAxis(&axisY, dirY);
    pthread_mutex_unlock(&stateMutex);

    startDisplayLinkIfNeeded();
    return 0;
}

static void resetAllState_Unsafe(void) {
    memset(&axisX, 0, sizeof(axisX));
    memset(&axisY, 0, sizeof(axisY));
    memset(&burst, 0, sizeof(burst));
    engPhase = PHASE_IDLE;
}

/// hs._ckol.smoothscroll.cancel() -> nil
/// Function
/// Drop any in-flight gesture / momentum. Stops the display link.
static int l_cancel(lua_State *L) {
    (void)L;
    pthread_mutex_lock(&stateMutex);
    resetAllState_Unsafe();
    pthread_mutex_unlock(&stateMutex);
    stopDisplayLink();
    return 0;
}

/// hs._ckol.smoothscroll.stop() -> nil
/// Function
/// Tear down the display link entirely (called by the Spoon's stop()).
static int l_stop(lua_State *L) {
    (void)L;
    pthread_mutex_lock(&stateMutex);
    resetAllState_Unsafe();
    pthread_mutex_unlock(&stateMutex);
    stopDisplayLink();
    return 0;
}

static const luaL_Reg moduleLib[] = {
    {"configure", l_configure},
    {"tick",      l_tick},
    {"cancel",    l_cancel},
    {"stop",      l_stop},
    {NULL, NULL}
};

/// Loader. require("hs._ckol.smoothscroll.internal") → luaopen_hs__ckol_smoothscroll_internal
int luaopen_hs__ckol_smoothscroll_internal(lua_State *L) {
    [LuaSkin sharedWithState:L];
    luaL_newlib(L, moduleLib);
    return 1;
}

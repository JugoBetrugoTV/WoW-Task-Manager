--[[--------------------------------------------------------------------------
    WoW Task Manager - Core/Constants.lua
    Every tunable number in one place.  Nothing below this file hardcodes a
    threshold, an interval or a limit.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C = {}
WTM.C = C

C.ADDON_NAME    = ADDON_NAME
C.ADDON_TITLE   = "WoW Task Manager"
C.ADDON_SHORT   = "WTM"
C.VERSION       = "0.7.1"

-- SavedVariables schema version.  Bump this whenever the stored shape changes
-- and add a migration step in Core/Database.lua; never reinterpret old data in
-- place without one.
C.SCHEMA_VERSION = 3

--------------------------------------------------------------------------
-- Spike classification
--------------------------------------------------------------------------
-- A spike is flagged when the frame time exceeds BOTH an absolute floor and a
-- multiple of the rolling baseline.  The absolute floor keeps a 240 Hz player
-- from drowning in "spikes"; the multiplier keeps a 30 Hz player from seeing
-- none at all.

C.SPIKE_KINDS = { "minor", "stutter", "heavy", "freeze" }

C.SPIKE_DEFAULTS = {
    minor   = { absMs = 33,  mult = 2.0, label = "Minor Stutter" },
    stutter = { absMs = 50,  mult = 3.0, label = "Stutter"       },
    heavy   = { absMs = 100, mult = 5.0, label = "Heavy Stutter" },
    freeze  = { absMs = 250, mult = 8.0, label = "Freeze"        },
}

C.SPIKE_ORDER = { freeze = 4, heavy = 3, stutter = 2, minor = 1 }

-- Do not raise a second incident within this many seconds of the previous one
-- of equal or lower severity.  A 400 ms freeze must produce one incident, not
-- four.
C.SPIKE_DEBOUNCE_SEC = 1.5

--------------------------------------------------------------------------
-- Incident coalescing
--------------------------------------------------------------------------
-- A stutter is rarely one bad frame.  Spikes arriving within this window are
-- folded into one "stutter cluster" carrying the peak, the duration and how
-- many frames were affected, instead of producing a wall of near-identical
-- incidents.

C.CLUSTER_WINDOW_SEC   = 2.0    -- a spike this soon after the last joins it
C.CLUSTER_MAX_SPAN_SEC = 10.0   -- a cluster is closed once it has run this long

--------------------------------------------------------------------------
-- False positive suppression
--------------------------------------------------------------------------
-- Frame times during a loading screen, the first seconds after login, a
-- /reload or a zone change are not stutter in any sense the user cares about.
-- They are recorded and counted, but as SUPPRESSED rather than as freezes.

C.WARMUP_LOGIN_SEC   = 12   -- after an initial login
C.WARMUP_RELOAD_SEC  = 8    -- after /reload
C.WARMUP_ZONE_SEC    = 5    -- after a zone change or loading screen ends

C.SUPPRESSION_REASONS = {
    loading  = "Loading screen",
    warmup   = "Warm-up after loading",
    login    = "Initial login",
    reload   = "UI reload",
    zone     = "Zone change",
    background = "Client likely in the background",
    disabled = "Spike detection disabled",
}

-- Background/alt-tab detection is a heuristic, not an API.  When maxFPSBk is
-- set, a backgrounded client renders at roughly that cap; if recent frames sit
-- near 1000/maxFPSBk for a sustained stretch we treat it as probably
-- backgrounded and label it as a guess wherever it is shown.
C.BACKGROUND_TOLERANCE   = 0.25   -- +/- 25% of the expected background frame time
C.BACKGROUND_MIN_SAMPLES = 3      -- consecutive samples before believing it

--------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------

C.SAMPLE_DEFAULTS = {
    frametime = { normal = 0.25, burst = 0.05 },
    events    = { normal = 1.00, burst = 0.25 },
    luamem    = { normal = 1.00, burst = 0.50 },
    cpu       = { normal = 2.00, burst = 0.50 },
    network   = { normal = 5.00, burst = 5.00 },
    -- Deliberately NOT faster during a burst. UpdateAddOnMemoryUsage walks the
    -- whole Lua heap and is the single most expensive call this addon makes; a
    -- live client spent most of its sampling budget here. Memory also does not
    -- change meaningfully inside a spike window, so bursting it buys nothing.
    memory    = { normal = 20.0, burst = 20.0 },
    history   = { normal = 1.00, burst = 1.00 },
    ui        = { normal = 0.50, burst = 0.50 },
}

-- How long the high-resolution burst lasts after the last spike.
C.BURST_DURATION_SEC = 10

-- Self-imposed budget.  Above this the scheduler stretches its own intervals
-- and the UI shows a warning; a monitor that costs more than it measures is a
-- bug, not a feature.
C.OVERHEAD_BUDGET_MS_PER_SEC = 2.0
C.OVERHEAD_CRITICAL_MS_PER_SEC = 6.0

--------------------------------------------------------------------------
-- Flight recorder
--------------------------------------------------------------------------

C.FR_PRE_WINDOW_SEC  = 30   -- kept before a spike
C.FR_POST_WINDOW_SEC = 15   -- captured after a spike
C.FR_RESERVE_SEC     = 15   -- headroom so the ring never eats its own tail
C.FR_MAX_INCIDENTS_MEM = 40 -- full-resolution incidents kept in RAM
C.FR_PERSIST_HZ      = 1    -- incidents are downsampled to this before saving

--------------------------------------------------------------------------
-- Frame time histogram (percentiles without storing every frame)
--------------------------------------------------------------------------
-- 64 buckets spanning 0..500 ms with quadratic spacing, so resolution is high
-- where it matters (4-40 ms) and coarse where it does not.

C.HIST_BUCKETS = 64
C.HIST_MAX_MS  = 500

--------------------------------------------------------------------------
-- History aggregation tiers
--------------------------------------------------------------------------
-- age (seconds) -> resolution (seconds).  Evaluated top to bottom.

C.HISTORY_TIERS = {
    { maxAge =   300, resolution =  1 },
    { maxAge =  1800, resolution =  5 },
    { maxAge = 10800, resolution = 15 },
    { maxAge = math.huge, resolution = 60 },
}

C.BUCKET_FIELDS = { "t", "fps", "frameAvgMs", "frameMaxMs", "latH", "latW", "luaKB", "events", "cpuMs" }

--------------------------------------------------------------------------
-- Event monitoring
--------------------------------------------------------------------------
-- RegisterAllEvents is genuinely not free in a raid, so the depth of event
-- monitoring is a user choice rather than a fixed cost.
--
--   OFF       no listener is registered at all
--   NORMAL    counts and rates only - the cheap handler
--   DETAILED  additionally tracks per-event CPU (needs scriptProfile) and
--             keeps a short per-event history for the storm analyser

C.EVENT_MODES = { "OFF", "NORMAL", "DETAILED" }
C.EVENT_MODE_LABELS = {
    OFF      = "Off - no event listener is registered",
    NORMAL   = "Normal - counts and rates only",
    DETAILED = "Detailed - adds per-event CPU and storm history",
}
C.EVENT_DETAIL_HISTORY = 60   -- per-event rate samples kept in DETAILED mode

C.EVENT_STORM_MIN_RATE   = 40    -- ignore anything quieter than this
C.EVENT_STORM_MULTIPLIER = 4.0   -- current rate vs. rolling baseline
C.EVENT_STORM_MIN_SEC    = 1.0   -- must persist this long to count
C.EVENT_BASELINE_ALPHA   = 0.05  -- EMA smoothing for the per-event baseline
C.EVENT_MAX_TRACKED      = 400   -- hard cap on distinct events in the table

--------------------------------------------------------------------------
-- Correlation labels
--------------------------------------------------------------------------
-- Deliberately worded as association, never causation.

C.CORRELATION_LEVELS = {
    { min = 0.75, label = "Strongly correlated", tone = "crit" },
    { min = 0.55, label = "Likely correlated",   tone = "warn" },
    { min = 0.30, label = "Possible contributor", tone = "warn" },
    { min = 0.00, label = "Weak association",    tone = "muted" },
}
C.CORRELATION_MIN_SAMPLES = 3

-- Frame pacing bands, in milliseconds. A frame at or under STABLE is one
-- nobody notices; the bands above it are where "it felt bad" starts. These are
-- descriptive thresholds for grouping frames, not a claim about perception.
C.FRAME_STABLE_MS = 20
C.FRAME_PACING_BANDS = {
    { label = "< 8.3 ms",     max = 8.34,   tone = "ok",   note = "120 FPS and above" },
    { label = "8.3 - 16.7",   max = 16.67,  tone = "ok",   note = "60 to 120 FPS" },
    { label = "16.7 - 33.3",  max = 33.34,  tone = "info", note = "30 to 60 FPS" },
    { label = "33.3 - 50",    max = 50,     tone = "warn", note = "20 to 30 FPS" },
    { label = "50 - 100",     max = 100,    tone = "warn", note = "10 to 20 FPS" },
    { label = "100 - 250",    max = 250,    tone = "crit", note = "visible hitch" },
    { label = "250 ms +",     max = math.huge, tone = "crit", note = "a freeze" },
}

--------------------------------------------------------------------------
-- Process status flags
--------------------------------------------------------------------------

C.STATUS = {
    NORMAL     = { key = "NORMAL",     text = "Normal",        tone = "muted" },
    HIGH_CPU   = { key = "HIGH_CPU",   text = "HIGH CPU",      tone = "crit"  },
    ELEVATED   = { key = "ELEVATED",   text = "Elevated CPU",  tone = "warn"  },
    MEM_GROWTH = { key = "MEM_GROWTH", text = "Memory growth", tone = "warn"  },
    SPIKY      = { key = "SPIKY",      text = "Spike source?", tone = "warn"  },
    IDLE       = { key = "IDLE",       text = "Idle",          tone = "muted" },
    NOT_LOADED = { key = "NOT_LOADED", text = "Not loaded",    tone = "muted" },
    DISABLED   = { key = "DISABLED",   text = "Disabled",      tone = "muted" },
}

C.HIGH_CPU_PCT     = 10.0   -- % of one core, sustained
C.ELEVATED_CPU_PCT = 4.0
C.MEM_GROWTH_KB_PER_MIN = 512   -- 0.5 MB/min sustained is worth a look

--------------------------------------------------------------------------
-- Data retention
--------------------------------------------------------------------------

C.MAX_SESSIONS       = 25
C.MAX_CLUSTERS       = 200
C.MAX_SAVED_INCIDENTS = 20
C.MAX_BUCKETS_PER_SESSION = 4000
C.MAX_TOP_LISTS      = 10

--------------------------------------------------------------------------
-- Time ranges offered in the UI
--------------------------------------------------------------------------

C.TIME_RANGES = {
    { key = "60s",     seconds = 60,    label = "60 s"    },
    { key = "5m",      seconds = 300,   label = "5 min"   },
    { key = "15m",     seconds = 900,   label = "15 min"  },
    { key = "30m",     seconds = 1800,  label = "30 min"  },
    { key = "1h",      seconds = 3600,  label = "1 h"     },
    { key = "session", seconds = 0,     label = "Session" },
}

--------------------------------------------------------------------------
-- Health scoring
--------------------------------------------------------------------------

-- Five bands rather than three. The middle of a three-band scale has to cover
-- everything from "a couple of hitches" to "nearly unplayable", which makes it
-- useless as a signal; splitting it gives the score somewhere to move.
C.HEALTH = {
    EXCELLENT = { key = "EXCELLENT", text = "EXCELLENT", tone = "ok",   min = 90 },
    GOOD      = { key = "GOOD",      text = "GOOD",      tone = "ok",   min = 75 },
    DEGRADED  = { key = "DEGRADED",  text = "DEGRADED",  tone = "warn", min = 55 },
    POOR      = { key = "POOR",      text = "POOR",      tone = "warn", min = 35 },
    CRITICAL  = { key = "CRITICAL",  text = "CRITICAL",  tone = "crit", min = 0  },
}

-- Ordered worst-first lookup, so a score maps to a band without a chain of ifs.
C.HEALTH_BANDS = {
    C.HEALTH.EXCELLENT, C.HEALTH.GOOD, C.HEALTH.DEGRADED,
    C.HEALTH.POOR, C.HEALTH.CRITICAL,
}

-- Kept so anything still asking for WARNING gets the band that replaced it.
C.HEALTH.WARNING = C.HEALTH.DEGRADED

--------------------------------------------------------------------------
-- Marker types for the timeline
--------------------------------------------------------------------------

C.MARKERS = {
    fpsdrop   = { glyph = "!",  label = "FPS Drop",     tone = "crit"   },
    cpuspike  = { glyph = "!",  label = "CPU Spike",    tone = "warn"   },
    memspike  = { glyph = "!",  label = "Memory Spike", tone = "warn"   },
    eventstorm= { glyph = "!",  label = "Event Storm",  tone = "warn"   },
    netspike  = { glyph = "!",  label = "Network Spike",tone = "warn"   },
    combat    = { glyph = "+",  label = "Combat",       tone = "accent" },
    encounter = { glyph = "*",  label = "Encounter",    tone = "accent" },
    zone      = { glyph = ">",  label = "Zone change",  tone = "muted"  },
    loading   = { glyph = "~",  label = "Loading screen",tone = "muted" },
    gc        = { glyph = ".",  label = "GC",           tone = "muted"  },
    -- Raised by a user-defined alert, and by the user pressing "Add marker" on
    -- the Recording page. Both belong on the shared time axis: an alert nobody
    -- can find again afterwards is a line of chat, not a diagnostic.
    alert     = { glyph = "!",  label = "Alert",        tone = "warn"   },
    custom    = { glyph = "#",  label = "Marker",       tone = "info"   },
    luaerror  = { glyph = "x",  label = "Lua error",    tone = "crit"   },
    errorstorm= { glyph = "X",  label = "Error storm",  tone = "crit"   },
}

--------------------------------------------------------------------------
-- Lua error monitoring
--------------------------------------------------------------------------
--
-- Errors are supposed to be rare, so the handler is allowed to do real work
-- for a NEW error. A storm is the case that has to stay cheap, which is what
-- the fingerprint fast path and these caps are for.

-- Distinct fingerprints held in memory. A session that produces more than this
-- has a problem the detail of the 401st bug will not help with.
C.ERROR_MAX_UNIQUE = 400

-- Longest stack trace stored per group, in characters. WoW stacks are rarely
-- longer than this; the cap exists so a pathological one cannot dominate the
-- saved database.
C.ERROR_MAX_STACK = 4000

-- Many errors in a short window, from anywhere.
C.ERROR_STORM_THRESHOLD  = 25
C.ERROR_STORM_WINDOW_SEC = 10

-- One fingerprint firing over and over. Distinct from a storm: a single bug
-- repeating is a different finding from a scatter of unrelated ones.
C.ERROR_REPEAT_THRESHOLD = 25

-- What kind of thing was captured. These are NOT all Lua errors, and the
-- distinction is kept everywhere it is shown: a blocked action is the client
-- refusing a call, not code that failed, and calling it an error would be
-- wrong in a way that sends people looking for a bug that is not there.
C.ERROR_KINDS = {
    lua       = { label = "Lua error",      short = "LUA",       tone = "crit" },
    forbidden = { label = "Blocked action", short = "BLOCKED",   tone = "warn" },
    warning   = { label = "Lua warning",    short = "WARNING",   tone = "warn" },
}

C.TXT_FORBIDDEN_NOTE =
    "The client refused a protected call from this addon. That is taint, not a " ..
    "crash: nothing threw, the call was simply not allowed. It usually starts " ..
    "somewhere else - whichever addon touched the protected path first - so the " ..
    "addon named here is where it surfaced, not necessarily where it began."

-- Buckets the error rate graph divides its window into. Ten over a ten-second
-- window is one per second, which is as fine as the data goes.
C.ERROR_RATE_BUCKETS = 10

-- Occurrence timestamps kept per group, newest overwriting oldest. This is a
-- fixed-size array written in place: a repeat costs one store, never an
-- allocation, so a storm cannot make the ring the thing that hurts.
C.ERROR_TIME_RING = 24

-- Distinct errors from one addon before the addon itself is the finding rather
-- than any one of its bugs.
C.ERROR_MULTI_THRESHOLD = 3

-- How far either side of an incident an error still counts as overlapping it.
-- Overlap in time only; nothing causal is claimed by it.
C.ERROR_INCIDENT_SLACK_SEC = 5

-- Errors saved to the database per session, and how many sessions of them.
C.ERROR_MAX_SAVED_GROUPS   = 60
C.ERROR_MAX_SAVED_SESSIONS = 5

-- Repeated internal faults before this addon starts switching its own pieces
-- off rather than continuing to throw.
C.SAFE_MODE_THRESHOLD  = 5
C.SAFE_MODE_WINDOW_SEC = 10

C.TXT_ERROR_OVERLAP_NOTE =
    "Overlap in time. An error and a stutter arriving together is a place to " ..
    "look, not a demonstration that one produced the other."

--------------------------------------------------------------------------
-- Context bit flags packed into a flight recorder slot
--------------------------------------------------------------------------

C.FLAG_COMBAT    = 1
C.FLAG_INSTANCE  = 2
C.FLAG_LOADING   = 4
C.FLAG_ENCOUNTER = 8
C.FLAG_GROUP     = 16
C.FLAG_RESTING   = 32

--------------------------------------------------------------------------
-- Strings shown when something genuinely is not available
--------------------------------------------------------------------------

C.TXT_UNAVAILABLE_CLIENT  = "Unavailable on this client"
C.TXT_REQUIRES_PROFILING  = "Requires CPU profiling"
C.TXT_COMBAT_BLOCKED      = "Unavailable during combat"
C.TXT_COMBAT_QUEUED       = "Queued until combat ends"
C.TXT_INSUFFICIENT        = "Insufficient data"

--------------------------------------------------------------------------
-- Wording rules
--------------------------------------------------------------------------
-- Centralised so the caution is consistent and testable rather than being
-- retyped (and softened) at each call site.

-- GetAddOnCPUUsage is CUMULATIVE. A delta measured over a ~1.4 s sampling
-- window cannot be attributed to one 84 ms frame inside it, so CPU figures
-- attached to a spike are always phrased as "within the observation window".
C.TXT_CPU_WINDOW_NOTE =
    "Addon CPU is cumulative and sampled on an interval. These figures are the CPU used " ..
    "across the whole observation window, not within the spiking frame - the API cannot " ..
    "attribute CPU to a single frame."

C.TXT_PHI_NOTE =
    "Phi is a measure of association between two yes/no observations across many samples. " ..
    "It is NOT a probability: phi 0.67 does not mean 67% likely, and it never demonstrates cause."

C.TXT_GC_NOTE =
    "WoW exposes no garbage collection statistics. A fall in the Lua heap is an observed " ..
    "decrease, which is consistent with collection activity but is not a measurement of it."

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
C.VERSION       = "0.1.0"
C.DB_VERSION    = 1

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
-- Sampling
--------------------------------------------------------------------------

C.SAMPLE_DEFAULTS = {
    frametime = { normal = 0.25, burst = 0.05 },
    events    = { normal = 1.00, burst = 0.25 },
    luamem    = { normal = 1.00, burst = 0.50 },
    cpu       = { normal = 2.00, burst = 0.50 },
    network   = { normal = 5.00, burst = 5.00 },
    memory    = { normal = 15.0, burst = 5.00 },
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

C.HEALTH = {
    GOOD     = { key = "GOOD",     text = "GOOD",     tone = "ok"   },
    WARNING  = { key = "WARNING",  text = "WARNING",  tone = "warn" },
    CRITICAL = { key = "CRITICAL", text = "CRITICAL", tone = "crit" },
}

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
}

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
C.TXT_HEURISTIC           = "heuristic"
C.TXT_INSUFFICIENT        = "Insufficient data"

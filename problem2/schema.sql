-- =============================================================================
-- WoT HEAT Data Engineer Test Task
-- Problem 2: Graphics Settings Schema
-- Dialect: PostgreSQL
-- Author: Igor Shushkov
-- =============================================================================


-- =============================================================================
-- LOOKUP TABLE
-- Stores the valid quality level values shared across all graphics dropdowns.
-- Examples: MINIMUM, LOW, MEDIUM, HIGH, ULTRA
-- =============================================================================

CREATE TABLE graphics_quality_levels (
    level_id    SERIAL      PRIMARY KEY,
    name        VARCHAR(32) NOT NULL UNIQUE  -- e.g. 'MINIMUM', 'LOW', 'MEDIUM', 'HIGH', 'ULTRA'
);


-- =============================================================================
-- graphics_profiles
-- Stores each UNIQUE combination of graphics settings exactly once.
--
-- Key idea: most players rarely change their settings. Instead of storing
-- 16 setting values on every battle row (repeated billions of times), we store
-- each distinct configuration once here and reference it by profile_id.
--
-- Deduplication is enforced via settings_hash: an MD5 digest of all setting
-- values concatenated. Before inserting a new profile, the application checks
-- whether a row with the same hash already exists and reuses it if so.
-- =============================================================================

CREATE TABLE graphics_profiles (
    profile_id      BIGSERIAL    PRIMARY KEY,

    -- Hash of all setting values — used for fast deduplication lookups.
    -- MD5 produces a 32-char hex string. UNIQUE enforces one row per config.
    settings_hash   CHAR(32)     NOT NULL UNIQUE,

    -- -------------------------------------------------------------------------
    -- DISPLAY SETTINGS
    -- -------------------------------------------------------------------------

    -- Free-form string because resolutions are player/hardware-dependent.
    resolution      VARCHAR(16)  NOT NULL,              -- e.g. '1920x1080'

    -- Categorical: WINDOWED, FULLSCREEN, BORDERLESS
    display_mode    VARCHAR(32)  NOT NULL,

    -- Free-form string: monitor model name reported by the OS.
    monitor         VARCHAR(128),

    -- -------------------------------------------------------------------------
    -- FIELD OF VIEW  (integer degrees, typically 40–120)
    -- -------------------------------------------------------------------------

    fov_ability_camera       SMALLINT NOT NULL CHECK (fov_ability_camera      BETWEEN 1 AND 360),
    fov_sniper_camera        SMALLINT NOT NULL CHECK (fov_sniper_camera       BETWEEN 1 AND 360),
    fov_third_person_camera  SMALLINT NOT NULL CHECK (fov_third_person_camera BETWEEN 1 AND 360),

    -- -------------------------------------------------------------------------
    -- DYNAMIC CAMERA EFFECTS  (percentage sliders 0–100, except gamma)
    -- -------------------------------------------------------------------------

    dce_linear_impact_effect   SMALLINT     NOT NULL CHECK (dce_linear_impact_effect  BETWEEN 0 AND 100),
    dce_angular_impact_effect  SMALLINT     NOT NULL CHECK (dce_angular_impact_effect BETWEEN 0 AND 100),
    dce_tilt_effect            SMALLINT     NOT NULL CHECK (dce_tilt_effect           BETWEEN 0 AND 100),

    -- Boolean toggle
    dce_vsync                  BOOLEAN      NOT NULL DEFAULT FALSE,

    -- Decimal value, typically in range 1.0–3.0
    dce_gamma                  NUMERIC(4,1) NOT NULL CHECK (dce_gamma BETWEEN 0.1 AND 9.9),

    -- -------------------------------------------------------------------------
    -- GRAPHICS SETTINGS  (all use the shared quality level lookup)
    -- -------------------------------------------------------------------------

    gfx_quality_preset   INT NOT NULL REFERENCES graphics_quality_levels(level_id),
    gfx_general          INT NOT NULL REFERENCES graphics_quality_levels(level_id),
    gfx_objects          INT NOT NULL REFERENCES graphics_quality_levels(level_id),
    gfx_terrain          INT NOT NULL REFERENCES graphics_quality_levels(level_id),
    gfx_lighting         INT NOT NULL REFERENCES graphics_quality_levels(level_id),
    gfx_shadows          INT NOT NULL REFERENCES graphics_quality_levels(level_id)
);

-- Index on hash for fast "does this profile already exist?" lookups on write.
-- The UNIQUE constraint above already creates an index, so no extra index needed.


-- =============================================================================
-- battle_graphics_settings
-- Links one participant in one battle to their graphics profile.
-- This is intentionally a tiny table: just two columns.
-- All the heavy setting data lives in graphics_profiles.
-- =============================================================================

CREATE TABLE battle_graphics_settings (
    participant_id  UUID    PRIMARY KEY REFERENCES battle_participants(participant_id),
    profile_id      BIGINT  NOT NULL    REFERENCES graphics_profiles(profile_id)
);

CREATE INDEX idx_bgs_profile_id ON battle_graphics_settings(profile_id);


-- =============================================================================
-- EXAMPLE: How deduplication works on write (application-side pseudo-logic)
--
--   hash = md5(resolution || display_mode || monitor || fov_ability || ...)
--
--   INSERT INTO graphics_profiles (settings_hash, resolution, ...)
--   VALUES (hash, '1920x1080', ...)
--   ON CONFLICT (settings_hash) DO NOTHING;
--
--   SELECT profile_id FROM graphics_profiles WHERE settings_hash = hash;
--
--   INSERT INTO battle_graphics_settings (participant_id, profile_id)
--   VALUES (participant_uuid, profile_id);
--
-- =============================================================================

-- =============================================================================
-- WoT HEAT Data Engineer Test Task
-- Problem 1: Battle Schema
-- Dialect: PostgreSQL
-- Author: Igor Shushkov
-- =============================================================================

-- -----------------------------------------------------------------------------
-- EXTENSIONS
-- -----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- provides gen_random_uuid()


-- =============================================================================
-- LOOKUP / DIMENSION TABLES
-- These are small, rarely-changing tables that store valid values.
-- Keeping them separate avoids repeating strings across billions of rows.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- players
-- Central registry of all players in the game.
-- -----------------------------------------------------------------------------
CREATE TABLE players (
    player_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    username     VARCHAR(64)  NOT NULL UNIQUE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- battle_types
-- Defines the type/scenario/ruleset of a battle (e.g. Ranked, Standard, Skirmish).
-- Storing this as a lookup avoids repeating type names across billions of battle rows.
-- -----------------------------------------------------------------------------
CREATE TABLE battle_types (
    battle_type_id   SERIAL       PRIMARY KEY,
    name             VARCHAR(64)  NOT NULL UNIQUE,
    description      TEXT
);

-- -----------------------------------------------------------------------------
-- maps
-- Defines the map/arena where a battle takes place.
-- -----------------------------------------------------------------------------
CREATE TABLE maps (
    map_id       SERIAL       PRIMARY KEY,
    name         VARCHAR(128) NOT NULL UNIQUE,
    external_id  VARCHAR(64)            -- ID used by the game engine / external systems
);

-- -----------------------------------------------------------------------------
-- death_reasons
-- Lookup table for the cause of a player's vehicle destruction or premature exit.
-- Examples: 'destroyed_by_player', 'destroyed_by_environment', 'disconnected', 'left_battle'
-- -----------------------------------------------------------------------------
CREATE TABLE death_reasons (
    death_reason_id   SERIAL      PRIMARY KEY,
    code              VARCHAR(64) NOT NULL UNIQUE,  -- machine-readable code
    description       TEXT                          -- human-readable label
);


-- =============================================================================
-- CORE FACT TABLES
-- These grow at the rate of game activity and will reach billions of rows.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- battles
-- One row per battle instance.
-- This is the central fact record - all other tables reference it.
-- -----------------------------------------------------------------------------
CREATE TABLE battles (
    battle_id        UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at       TIMESTAMPTZ  NOT NULL,
    duration_seconds INT          NOT NULL CHECK (duration_seconds > 0),
    battle_type_id   INT          NOT NULL REFERENCES battle_types(battle_type_id),
    map_id           INT          NOT NULL REFERENCES maps(map_id),

    -- NULL means draw; 1 or 2 refers to the team number that won
    winning_team     SMALLINT              CHECK (winning_team IN (1, 2)),

    -- Which game server hosted this battle (useful for debugging and partitioning)
    server_id        VARCHAR(64)
);

CREATE INDEX idx_battles_started_at      ON battles(started_at);
CREATE INDEX idx_battles_battle_type_id  ON battles(battle_type_id);
CREATE INDEX idx_battles_map_id          ON battles(map_id);


-- -----------------------------------------------------------------------------
-- battle_participants
-- One row per player per battle.
-- Captures identity, team, role, and outcome for each participant.
-- -----------------------------------------------------------------------------
CREATE TABLE battle_participants (
    participant_id     UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    battle_id          UUID         NOT NULL REFERENCES battles(battle_id),
    player_id          UUID         NOT NULL REFERENCES players(player_id),

    -- Team number (1 or 2) the player belonged to in this battle
    team_number        SMALLINT     NOT NULL CHECK (team_number IN (1, 2)),

    -- Whether this player survived the battle
    survived           BOOLEAN      NOT NULL DEFAULT FALSE,

    -- Cause of death or early exit - NULL if player survived
    death_reason_id    INT                   REFERENCES death_reasons(death_reason_id),

    -- The player who destroyed this player's vehicle - NULL if survived or environment kill
    destroyed_by_player_id  UUID             REFERENCES players(player_id),

    -- Whether the player voluntarily left the battle before it ended
    left_early         BOOLEAN      NOT NULL DEFAULT FALSE,

    UNIQUE (battle_id, player_id)  -- a player can only appear once per battle
);

CREATE INDEX idx_participants_battle_id  ON battle_participants(battle_id);
CREATE INDEX idx_participants_player_id  ON battle_participants(player_id);


-- -----------------------------------------------------------------------------
-- battle_player_stats
-- One row per player per battle - combat performance metrics.
-- Kept separate from battle_participants to isolate the high-cardinality numeric data
-- and make it easier to add new stat columns without touching the identity table.
-- -----------------------------------------------------------------------------
CREATE TABLE battle_player_stats (
    participant_id       UUID    PRIMARY KEY REFERENCES battle_participants(participant_id),

    -- Damage metrics (in HP)
    damage_dealt         INT     NOT NULL DEFAULT 0,
    damage_assisted      INT     NOT NULL DEFAULT 0,  -- e.g. via spotting or tracking
    damage_received      INT     NOT NULL DEFAULT 0,

    -- Kill / destruction counts
    kills                INT     NOT NULL DEFAULT 0,
    vehicles_spotted     INT     NOT NULL DEFAULT 0,

    -- Shots
    shots_fired          INT     NOT NULL DEFAULT 0,
    shots_hit            INT     NOT NULL DEFAULT 0,
    shots_penetrated     INT     NOT NULL DEFAULT 0,

    -- Score / experience
    experience_earned    INT     NOT NULL DEFAULT 0,
    base_xp              INT     NOT NULL DEFAULT 0
);


-- -----------------------------------------------------------------------------
-- battle_player_economy
-- One row per player per battle - virtual currency flows.
-- Separated from stats for the same narrow-table reasoning:
-- currency schema may change independently of combat stats.
-- -----------------------------------------------------------------------------
CREATE TABLE battle_player_economy (
    participant_id    UUID    PRIMARY KEY REFERENCES battle_participants(participant_id),

    -- Credits (standard in-game currency)
    credits_earned    INT     NOT NULL DEFAULT 0,
    credits_spent     INT     NOT NULL DEFAULT 0,

    -- Premium currency
    gold_earned       INT     NOT NULL DEFAULT 0,
    gold_spent        INT     NOT NULL DEFAULT 0,

    -- Bonds (high-tier currency)
    bonds_earned      INT     NOT NULL DEFAULT 0,
    bonds_spent       INT     NOT NULL DEFAULT 0
);

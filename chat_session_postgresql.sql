-- ============================================================
--  CHAT SESSION DATABASE SCHEMA — PostgreSQL  v3
--  Changes: UUID → BIGINT, SESSION_LEG table added,
--           TRANSFER_EVENT table added, messages link to leg
-- ============================================================

-- ── TABLE 1: CHAT_SESSION  (ROOT)
CREATE TABLE chat_session (
    session_id   BIGINT       NOT NULL GENERATED ALWAYS AS IDENTITY,
    start_time   TIMESTAMP    NOT NULL DEFAULT NOW(),
    end_time     TIMESTAMP,
    status       VARCHAR(32)  NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active','ended','dropped','license_exceeded')),
    channel      VARCHAR(32),
    created_at   TIMESTAMP    NOT NULL DEFAULT NOW(),
    metadata     JSONB,
    CONSTRAINT pk_chat_session PRIMARY KEY (session_id)
);
CREATE INDEX idx_cs_status    ON chat_session (status);
CREATE INDEX idx_cs_created   ON chat_session (created_at DESC);

-- ── TABLE 2: MOBILE_DEVICE  (1:1 with session)
CREATE TABLE mobile_device (
    device_id          BIGINT       NOT NULL GENERATED ALWAYS AS IDENTITY,
    session_id         BIGINT       NOT NULL,
    mobile_id          VARCHAR(64)  NOT NULL,
    platform           VARCHAR(32),
    os_version         VARCHAR(32),
    app_version        VARCHAR(32),
    device_fingerprint VARCHAR(128),
    captured_at        TIMESTAMP    NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_mobile_device    PRIMARY KEY (device_id),
    CONSTRAINT fk_md_session       FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT uq_mobile_device_id UNIQUE (mobile_id)
);
CREATE INDEX idx_md_session   ON mobile_device (session_id);
CREATE INDEX idx_md_mobile_id ON mobile_device (mobile_id);

-- ── TABLE 3: UCID_MAPPING  (async 1:1 with session)
CREATE TABLE ucid_mapping (
    ucid_map_id       BIGINT       NOT NULL GENERATED ALWAYS AS IDENTITY,
    session_id        BIGINT       NOT NULL,
    ucid_value        VARCHAR(128) NOT NULL,
    mobile_id         VARCHAR(64),
    resolved_at       TIMESTAMP    NOT NULL DEFAULT NOW(),
    source_system     VARCHAR(64),
    resolution_status VARCHAR(32)  NOT NULL DEFAULT 'resolved'
                                   CHECK (resolution_status IN ('resolved','failed','pending')),
    notes             TEXT,
    CONSTRAINT pk_ucid_mapping PRIMARY KEY (ucid_map_id),
    CONSTRAINT fk_um_session   FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT uq_ucid_value   UNIQUE (ucid_value)
);
CREATE INDEX idx_um_session ON ucid_mapping (session_id);
CREATE INDEX idx_um_value   ON ucid_mapping (ucid_value);

-- ── TABLE 4: SESSION_LEG  (1:N with session — core new table)
--    One row per participant segment. Tracks every Agent/Bot/Supervisor
--    that handled a portion of the session. prev_leg_id enables transfer chain.
CREATE TABLE session_leg (
    leg_id            BIGINT       NOT NULL GENERATED ALWAYS AS IDENTITY,
    session_id        BIGINT       NOT NULL,
    leg_sequence      INT          NOT NULL,          -- order within session (1=first)
    participant_type  VARCHAR(16)  NOT NULL
                                   CHECK (participant_type IN ('customer','agent','supervisor','bot')),
    -- participant IDs (only one will be non-NULL per row)
    customer_id       BIGINT,
    agent_id          BIGINT,
    supervisor_id     BIGINT,
    bot_id            BIGINT,
    -- transfer chain
    prev_leg_id       BIGINT,                         -- NULL for first leg; FK to self
    transfer_reason   VARCHAR(128),                   -- why transfer happened
    -- timing
    leg_start         TIMESTAMP    NOT NULL DEFAULT NOW(),
    leg_end           TIMESTAMP,                      -- NULL while active
    leg_status        VARCHAR(32)  NOT NULL DEFAULT 'active'
                                   CHECK (leg_status IN ('active','completed','transferred','dropped')),
    CONSTRAINT pk_session_leg    PRIMARY KEY (leg_id),
    CONSTRAINT fk_sl_session     FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT fk_sl_prev_leg    FOREIGN KEY (prev_leg_id) REFERENCES session_leg(leg_id),
    CONSTRAINT uq_sl_sequence    UNIQUE (session_id, leg_sequence)
);
CREATE INDEX idx_sl_session     ON session_leg (session_id);
CREATE INDEX idx_sl_customer    ON session_leg (customer_id)   WHERE customer_id   IS NOT NULL;
CREATE INDEX idx_sl_agent       ON session_leg (agent_id)      WHERE agent_id      IS NOT NULL;
CREATE INDEX idx_sl_supervisor  ON session_leg (supervisor_id) WHERE supervisor_id IS NOT NULL;
CREATE INDEX idx_sl_bot         ON session_leg (bot_id)        WHERE bot_id        IS NOT NULL;
CREATE INDEX idx_sl_prev_leg    ON session_leg (prev_leg_id)   WHERE prev_leg_id   IS NOT NULL;

-- ── TABLE 5: TRANSFER_EVENT  (1:N with session — full audit of each transfer)
CREATE TABLE transfer_event (
    transfer_id       BIGINT       NOT NULL GENERATED ALWAYS AS IDENTITY,
    session_id        BIGINT       NOT NULL,
    from_leg_id       BIGINT       NOT NULL,
    to_leg_id         BIGINT,                         -- NULL until receiving leg is created
    transfer_type     VARCHAR(32)  NOT NULL
                                   CHECK (transfer_type IN (
                                     'agent_to_agent','agent_to_supervisor',
                                     'bot_to_agent','bot_to_supervisor',
                                     'customer_to_agent','agent_to_bot')),
    transfer_reason   VARCHAR(128),
    initiated_by      VARCHAR(16)  CHECK (initiated_by IN ('customer','agent','supervisor','bot','system')),
    transferred_at    TIMESTAMP    NOT NULL DEFAULT NOW(),
    completed_at      TIMESTAMP,                      -- NULL until receiving side picks up
    status            VARCHAR(32)  NOT NULL DEFAULT 'pending'
                                   CHECK (status IN ('pending','completed','failed')),
    CONSTRAINT pk_transfer_event PRIMARY KEY (transfer_id),
    CONSTRAINT fk_te_session     FOREIGN KEY (session_id)  REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT fk_te_from_leg    FOREIGN KEY (from_leg_id) REFERENCES session_leg(leg_id),
    CONSTRAINT fk_te_to_leg      FOREIGN KEY (to_leg_id)   REFERENCES session_leg(leg_id)
);
CREATE INDEX idx_te_session  ON transfer_event (session_id);
CREATE INDEX idx_te_from_leg ON transfer_event (from_leg_id);
CREATE INDEX idx_te_to_leg   ON transfer_event (to_leg_id) WHERE to_leg_id IS NOT NULL;

-- ── TABLE 6: CHAT_MESSAGE  (1:N with session_leg)
--    Messages now link to the LEG so you know exactly which participant sent each message.
CREATE TABLE chat_message (
    message_id   BIGINT      NOT NULL GENERATED ALWAYS AS IDENTITY,
    session_id   BIGINT      NOT NULL,
    leg_id       BIGINT      NOT NULL,
    sequence_no  INT         NOT NULL,                -- ordered within session
    sender_type  VARCHAR(16) NOT NULL CHECK (sender_type IN ('customer','agent','supervisor','bot')),
    sender_id    BIGINT,                              -- customer_id / agent_id / supervisor_id / bot_id
    message_type VARCHAR(32),
    content      TEXT,
    raw_payload  JSONB,
    sent_at      TIMESTAMP,
    received_at  TIMESTAMP   NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_chat_message PRIMARY KEY (message_id),
    CONSTRAINT fk_cm_session   FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT fk_cm_leg       FOREIGN KEY (leg_id)     REFERENCES session_leg(leg_id),
    CONSTRAINT uq_cm_sequence  UNIQUE (session_id, sequence_no)
);
CREATE INDEX idx_cm_session_seq ON chat_message (session_id, sequence_no ASC);
CREATE INDEX idx_cm_leg         ON chat_message (leg_id);
CREATE INDEX idx_cm_sender      ON chat_message (sender_id, sent_at DESC);

-- ── TABLE 7: DISCONNECT_EVENT  (1:1 with session)
CREATE TABLE disconnect_event (
    disconnect_id    BIGINT    NOT NULL GENERATED ALWAYS AS IDENTITY,
    session_id       BIGINT    NOT NULL,
    reason_code      VARCHAR(64),
    reason_detail    TEXT,
    is_license_limit BOOLEAN   NOT NULL DEFAULT FALSE,
    tcomm_triggered  BOOLEAN   NOT NULL DEFAULT FALSE,
    error_code       VARCHAR(32),
    disconnected_at  TIMESTAMP NOT NULL DEFAULT NOW(),
    raw_payload      JSONB,
    CONSTRAINT pk_disconnect_event PRIMARY KEY (disconnect_id),
    CONSTRAINT fk_de_session       FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT uq_de_session       UNIQUE (session_id)
);
CREATE INDEX idx_de_license_limit ON disconnect_event (is_license_limit, disconnected_at DESC);
CREATE INDEX idx_de_tcomm         ON disconnect_event (tcomm_triggered,  disconnected_at DESC);

-- ── TABLE 8: LICENSE_EVENT  (independent audit, session_id nullable)
CREATE TABLE license_event (
    license_event_id  BIGINT    NOT NULL GENERATED ALWAYS AS IDENTITY,
    session_id        BIGINT,                         -- NULLABLE: pre-session events
    mobile_id         VARCHAR(64),
    event_type        VARCHAR(64),
    license_limit_hit BOOLEAN   NOT NULL DEFAULT FALSE,
    concurrent_count  INT,
    max_allowed       INT,
    triggered_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    raw_payload       JSONB,
    CONSTRAINT pk_license_event PRIMARY KEY (license_event_id),
    CONSTRAINT fk_le_session    FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE SET NULL
);
CREATE INDEX idx_le_limit_hit    ON license_event (license_limit_hit, triggered_at DESC);
CREATE INDEX idx_le_null_session ON license_event (triggered_at DESC) WHERE session_id IS NULL;

-- ── TABLE 9: LEG_DISCONNECT  (1:1 with session_leg)
--    Captures why and when each individual leg ended.
--    Gives you per-participant disconnect details, not just session-level.
CREATE TABLE leg_disconnect (
    leg_disconnect_id  BIGINT       NOT NULL GENERATED ALWAYS AS IDENTITY,
    leg_id             BIGINT       NOT NULL,          -- the leg that ended
    session_id         BIGINT       NOT NULL,          -- denorm for direct session queries
    participant_type   VARCHAR(16)  NOT NULL
                                    CHECK (participant_type IN ('customer','agent','supervisor','bot')),
    -- which participant ended (mirrors session_leg ID columns)
    customer_id        BIGINT,
    agent_id           BIGINT,
    supervisor_id      BIGINT,
    bot_id             BIGINT,
    -- timing
    leg_start          TIMESTAMP    NOT NULL,          -- copied from session_leg.leg_start
    leg_end            TIMESTAMP    NOT NULL DEFAULT NOW(),
    duration_seconds   INT          GENERATED ALWAYS AS
                                    (EXTRACT(EPOCH FROM (leg_end - leg_start))::INT) STORED,
    -- why did this leg end?
    end_reason         VARCHAR(32)  NOT NULL
                                    CHECK (end_reason IN (
                                      'transferred','completed','dropped',
                                      'license_exceeded','timeout','error')),
    reason_detail      TEXT,
    error_code         VARCHAR(32),
    -- was this leg killed by a license limit?
    is_license_limit   BOOLEAN      NOT NULL DEFAULT FALSE,
    tcomm_triggered    BOOLEAN      NOT NULL DEFAULT FALSE,
    -- if transferred: which transfer caused this leg to end?
    transfer_id        BIGINT,                         -- FK to transfer_event (nullable)
    next_leg_id        BIGINT,                         -- the leg that replaced this one
    raw_payload        JSONB,

    CONSTRAINT pk_leg_disconnect   PRIMARY KEY (leg_disconnect_id),
    CONSTRAINT fk_ld_leg           FOREIGN KEY (leg_id)       REFERENCES session_leg(leg_id),
    CONSTRAINT fk_ld_session       FOREIGN KEY (session_id)   REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT fk_ld_transfer      FOREIGN KEY (transfer_id)  REFERENCES transfer_event(transfer_id),
    CONSTRAINT fk_ld_next_leg      FOREIGN KEY (next_leg_id)  REFERENCES session_leg(leg_id),
    CONSTRAINT uq_ld_leg           UNIQUE (leg_id)             -- one disconnect record per leg
);
CREATE INDEX idx_ld_session       ON leg_disconnect (session_id);
CREATE INDEX idx_ld_leg           ON leg_disconnect (leg_id);
CREATE INDEX idx_ld_end_reason    ON leg_disconnect (end_reason, leg_end DESC);
CREATE INDEX idx_ld_license       ON leg_disconnect (is_license_limit, leg_end DESC) WHERE is_license_limit = TRUE;
CREATE INDEX idx_ld_agent         ON leg_disconnect (agent_id, leg_end DESC)         WHERE agent_id IS NOT NULL;
CREATE INDEX idx_ld_duration      ON leg_disconnect (duration_seconds DESC);

-- ============================================================
--  CHAT SESSION DATABASE SCHEMA — MS SQL Server (T-SQL)  v3
--  Changes: UUID → BIGINT (IDENTITY), SESSION_LEG added,
--           TRANSFER_EVENT added, messages link to leg
-- ============================================================
USE ChatSessionDB;
GO

-- ── TABLE 1: CHAT_SESSION  (ROOT)
CREATE TABLE chat_session (
    session_id   BIGINT       NOT NULL IDENTITY(1,1),
    start_time   DATETIME2    NOT NULL DEFAULT SYSDATETIME(),
    end_time     DATETIME2    NULL,
    status       NVARCHAR(32) NOT NULL DEFAULT 'active'
                              CONSTRAINT chk_cs_status CHECK (
                                status IN ('active','ended','dropped','license_exceeded')),
    channel      NVARCHAR(32) NULL,
    created_at   DATETIME2    NOT NULL DEFAULT SYSDATETIME(),
    metadata     NVARCHAR(MAX) NULL,
    CONSTRAINT PK_chat_session PRIMARY KEY CLUSTERED (session_id)
);
GO
CREATE NONCLUSTERED INDEX IDX_cs_status  ON chat_session (status);
CREATE NONCLUSTERED INDEX IDX_cs_created ON chat_session (created_at DESC);
GO

-- ── TABLE 2: MOBILE_DEVICE
CREATE TABLE mobile_device (
    device_id          BIGINT       NOT NULL IDENTITY(1,1),
    session_id         BIGINT       NOT NULL,
    mobile_id          NVARCHAR(64) NOT NULL,
    platform           NVARCHAR(32) NULL,
    os_version         NVARCHAR(32) NULL,
    app_version        NVARCHAR(32) NULL,
    device_fingerprint NVARCHAR(128) NULL,
    captured_at        DATETIME2    NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_mobile_device    PRIMARY KEY CLUSTERED (device_id),
    CONSTRAINT FK_md_session       FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT UQ_mobile_device_id UNIQUE (mobile_id)
);
GO
CREATE NONCLUSTERED INDEX IDX_md_session   ON mobile_device (session_id);
CREATE NONCLUSTERED INDEX IDX_md_mobile_id ON mobile_device (mobile_id);
GO

-- ── TABLE 3: UCID_MAPPING
CREATE TABLE ucid_mapping (
    ucid_map_id       BIGINT        NOT NULL IDENTITY(1,1),
    session_id        BIGINT        NOT NULL,
    ucid_value        NVARCHAR(128) NOT NULL,
    mobile_id         NVARCHAR(64)  NULL,
    resolved_at       DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    source_system     NVARCHAR(64)  NULL,
    resolution_status NVARCHAR(32)  NOT NULL DEFAULT 'resolved'
                                    CONSTRAINT chk_um_status CHECK (
                                      resolution_status IN ('resolved','failed','pending')),
    notes             NVARCHAR(MAX) NULL,
    CONSTRAINT PK_ucid_mapping PRIMARY KEY CLUSTERED (ucid_map_id),
    CONSTRAINT FK_um_session   FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT UQ_ucid_value   UNIQUE (ucid_value)
);
GO
CREATE NONCLUSTERED INDEX IDX_um_session ON ucid_mapping (session_id);
CREATE NONCLUSTERED INDEX IDX_um_value   ON ucid_mapping (ucid_value);
GO

-- ── TABLE 4: SESSION_LEG  (1:N — core routing table)
--    prev_leg_id is a self-referencing FK — tracks transfer chain.
CREATE TABLE session_leg (
    leg_id            BIGINT        NOT NULL IDENTITY(1,1),
    session_id        BIGINT        NOT NULL,
    leg_sequence      INT           NOT NULL,
    participant_type  NVARCHAR(16)  NOT NULL
                                    CONSTRAINT chk_sl_type CHECK (
                                      participant_type IN ('customer','agent','supervisor','bot')),
    customer_id       BIGINT        NULL,
    agent_id          BIGINT        NULL,
    supervisor_id     BIGINT        NULL,
    bot_id            BIGINT        NULL,
    prev_leg_id       BIGINT        NULL,
    transfer_reason   NVARCHAR(128) NULL,
    leg_start         DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    leg_end           DATETIME2     NULL,
    leg_status        NVARCHAR(32)  NOT NULL DEFAULT 'active'
                                    CONSTRAINT chk_sl_status CHECK (
                                      leg_status IN ('active','completed','transferred','dropped')),
    CONSTRAINT PK_session_leg    PRIMARY KEY CLUSTERED (leg_id),
    CONSTRAINT FK_sl_session     FOREIGN KEY (session_id)  REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT FK_sl_prev_leg    FOREIGN KEY (prev_leg_id) REFERENCES session_leg(leg_id),
    CONSTRAINT UQ_sl_sequence    UNIQUE (session_id, leg_sequence)
);
GO
CREATE NONCLUSTERED INDEX IDX_sl_session    ON session_leg (session_id);
CREATE NONCLUSTERED INDEX IDX_sl_customer   ON session_leg (customer_id)   WHERE customer_id   IS NOT NULL;
CREATE NONCLUSTERED INDEX IDX_sl_agent      ON session_leg (agent_id)      WHERE agent_id      IS NOT NULL;
CREATE NONCLUSTERED INDEX IDX_sl_supervisor ON session_leg (supervisor_id) WHERE supervisor_id IS NOT NULL;
CREATE NONCLUSTERED INDEX IDX_sl_bot        ON session_leg (bot_id)        WHERE bot_id        IS NOT NULL;
CREATE NONCLUSTERED INDEX IDX_sl_prev_leg   ON session_leg (prev_leg_id)   WHERE prev_leg_id   IS NOT NULL;
GO

-- ── TABLE 5: TRANSFER_EVENT  (full transfer audit)
CREATE TABLE transfer_event (
    transfer_id       BIGINT        NOT NULL IDENTITY(1,1),
    session_id        BIGINT        NOT NULL,
    from_leg_id       BIGINT        NOT NULL,
    to_leg_id         BIGINT        NULL,
    transfer_type     NVARCHAR(32)  NOT NULL
                                    CONSTRAINT chk_te_type CHECK (
                                      transfer_type IN (
                                        'agent_to_agent','agent_to_supervisor',
                                        'bot_to_agent','bot_to_supervisor',
                                        'customer_to_agent','agent_to_bot')),
    transfer_reason   NVARCHAR(128) NULL,
    initiated_by      NVARCHAR(16)  NULL
                                    CONSTRAINT chk_te_init CHECK (
                                      initiated_by IN ('customer','agent','supervisor','bot','system')),
    transferred_at    DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    completed_at      DATETIME2     NULL,
    status            NVARCHAR(32)  NOT NULL DEFAULT 'pending'
                                    CONSTRAINT chk_te_status CHECK (
                                      status IN ('pending','completed','failed')),
    CONSTRAINT PK_transfer_event PRIMARY KEY CLUSTERED (transfer_id),
    CONSTRAINT FK_te_session     FOREIGN KEY (session_id)  REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT FK_te_from_leg    FOREIGN KEY (from_leg_id) REFERENCES session_leg(leg_id),
    CONSTRAINT FK_te_to_leg      FOREIGN KEY (to_leg_id)   REFERENCES session_leg(leg_id)
);
GO
CREATE NONCLUSTERED INDEX IDX_te_session  ON transfer_event (session_id);
CREATE NONCLUSTERED INDEX IDX_te_from_leg ON transfer_event (from_leg_id);
CREATE NONCLUSTERED INDEX IDX_te_to_leg   ON transfer_event (to_leg_id) WHERE to_leg_id IS NOT NULL;
GO

-- ── TABLE 6: CHAT_MESSAGE  (1:N with session_leg)
CREATE TABLE chat_message (
    message_id   BIGINT        NOT NULL IDENTITY(1,1),
    session_id   BIGINT        NOT NULL,
    leg_id       BIGINT        NOT NULL,
    sequence_no  INT           NOT NULL,
    sender_type  NVARCHAR(16)  NOT NULL
                               CONSTRAINT chk_cm_sender CHECK (
                                 sender_type IN ('customer','agent','supervisor','bot')),
    sender_id    BIGINT        NULL,
    message_type NVARCHAR(32)  NULL,
    content      NVARCHAR(MAX) NULL,
    raw_payload  NVARCHAR(MAX) NULL,
    sent_at      DATETIME2     NULL,
    received_at  DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_chat_message PRIMARY KEY CLUSTERED (message_id),
    CONSTRAINT FK_cm_session   FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT FK_cm_leg       FOREIGN KEY (leg_id)     REFERENCES session_leg(leg_id),
    CONSTRAINT UQ_cm_sequence  UNIQUE (session_id, sequence_no)
);
GO
CREATE NONCLUSTERED INDEX IDX_cm_session_seq ON chat_message (session_id, sequence_no ASC);
CREATE NONCLUSTERED INDEX IDX_cm_leg         ON chat_message (leg_id);
CREATE NONCLUSTERED INDEX IDX_cm_sender      ON chat_message (sender_id, sent_at DESC) WHERE sender_id IS NOT NULL;
GO

-- ── TABLE 7: DISCONNECT_EVENT
CREATE TABLE disconnect_event (
    disconnect_id    BIGINT        NOT NULL IDENTITY(1,1),
    session_id       BIGINT        NOT NULL,
    reason_code      NVARCHAR(64)  NULL,
    reason_detail    NVARCHAR(MAX) NULL,
    is_license_limit BIT           NOT NULL DEFAULT 0,
    tcomm_triggered  BIT           NOT NULL DEFAULT 0,
    error_code       NVARCHAR(32)  NULL,
    disconnected_at  DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    raw_payload      NVARCHAR(MAX) NULL,
    CONSTRAINT PK_disconnect_event PRIMARY KEY CLUSTERED (disconnect_id),
    CONSTRAINT FK_de_session       FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE CASCADE,
    CONSTRAINT UQ_de_session       UNIQUE (session_id)
);
GO
CREATE NONCLUSTERED INDEX IDX_de_license_limit ON disconnect_event (is_license_limit, disconnected_at DESC);
CREATE NONCLUSTERED INDEX IDX_de_tcomm         ON disconnect_event (tcomm_triggered,  disconnected_at DESC);
GO

-- ── TABLE 8: LICENSE_EVENT  (session_id nullable — independent audit)
CREATE TABLE license_event (
    license_event_id  BIGINT        NOT NULL IDENTITY(1,1),
    session_id        BIGINT        NULL,
    mobile_id         NVARCHAR(64)  NULL,
    event_type        NVARCHAR(64)  NULL,
    license_limit_hit BIT           NOT NULL DEFAULT 0,
    concurrent_count  INT           NULL,
    max_allowed       INT           NULL,
    triggered_at      DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    raw_payload       NVARCHAR(MAX) NULL,
    CONSTRAINT PK_license_event PRIMARY KEY CLUSTERED (license_event_id),
    CONSTRAINT FK_le_session    FOREIGN KEY (session_id) REFERENCES chat_session(session_id) ON DELETE SET NULL
);
GO
CREATE NONCLUSTERED INDEX IDX_le_limit_hit    ON license_event (license_limit_hit, triggered_at DESC);
CREATE NONCLUSTERED INDEX IDX_le_null_session ON license_event (triggered_at DESC) WHERE session_id IS NULL;
GO

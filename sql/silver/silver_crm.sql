-- Silver — dominio crm
-- Reglas y justificación de cada decisión: docs/decisiones.md (secciones 2, 3 y 4).
-- Política general: no se borra ni se "corrige" ninguna fila por inconsistencia de
-- fecha/negocio; se tipa, se estandariza y se marca con columnas _dq_* cuando aplica.

CREATE SCHEMA IF NOT EXISTS silver;

-- ---------------------------------------------------------------------------
-- accounts: 599 nombres repetidos con industry/country distintos por
-- account_id -> son empresas distintas, NO se deduplica (docs/decisiones.md
-- §2.2). Se agrega name_occurrence_count informativo (no es un _dq_ booleano,
-- es un conteo para que Gold pueda decidir si el nombre es confiable como
-- identificador de negocio).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.crm_accounts CASCADE;
CREATE TABLE silver.crm_accounts AS
SELECT
    TRIM(account_id)                                        AS account_id,
    TRIM(name)                                                AS name,
    TRIM(industry)                                            AS industry,
    TRIM(country)                                             AS country,
    annual_revenue::NUMERIC(14, 2)                            AS annual_revenue,
    employees::INTEGER                                        AS employees,
    created_at::TIMESTAMP                                     AS created_at,
    COUNT(*) OVER (PARTITION BY TRIM(name))                   AS name_occurrence_count,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'                                  AS _silver_loaded_at
FROM bronze.crm_accounts;

ALTER TABLE silver.crm_accounts ADD PRIMARY KEY (account_id);

-- ---------------------------------------------------------------------------
-- contacts: 49,7% con created_at anterior al de su cuenta — imposible
-- cronológicamente, se marca sin corregir (docs/decisiones.md §2.5 y §3).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.crm_contacts CASCADE;
CREATE TABLE silver.crm_contacts AS
SELECT
    TRIM(ct.contact_id)                                       AS contact_id,
    TRIM(ct.first_name)                                       AS first_name,
    TRIM(ct.last_name)                                        AS last_name,
    LOWER(TRIM(ct.email))                                     AS email,
    TRIM(ct.phone)                                            AS phone,
    TRIM(ct.title)                                             AS title,
    ct.created_at::TIMESTAMP                                   AS created_at,
    TRIM(ct.account_id)                                        AS account_id,
    COALESCE(ct.created_at::TIMESTAMP < a.created_at::TIMESTAMP, FALSE)
                                                                AS _dq_created_before_account,
    ct._source_domain,
    ct._source_file,
    ct._ingested_at,
    now() AT TIME ZONE 'UTC'                                  AS _silver_loaded_at
FROM bronze.crm_contacts ct
LEFT JOIN bronze.crm_accounts a
    ON a.account_id = ct.account_id;

ALTER TABLE silver.crm_contacts ADD PRIMARY KEY (contact_id);

-- ---------------------------------------------------------------------------
-- leads: sin FK por diseño, tabla aislada (docs/decisiones.md §1.3). Solo
-- tipado.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.crm_leads CASCADE;
CREATE TABLE silver.crm_leads AS
SELECT
    TRIM(lead_id)                 AS lead_id,
    TRIM(first_name)              AS first_name,
    TRIM(last_name)               AS last_name,
    LOWER(TRIM(email))            AS email,
    TRIM(source)                  AS source,
    TRIM(status)                  AS status,
    score::INTEGER                AS score,
    created_at::TIMESTAMP         AS created_at,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'      AS _silver_loaded_at
FROM bronze.crm_leads;

ALTER TABLE silver.crm_leads ADD PRIMARY KEY (lead_id);

-- ---------------------------------------------------------------------------
-- opportunities: close_date presente en el 100% de las filas (incluidas
-- etapas abiertas) -> se reinterpreta como fecha de cierre ESTIMADA, no real
-- (docs/decisiones.md §2.6). 34,3% con close_date anterior a created_at,
-- sigue marcándose bajo esa lectura.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.crm_opportunities CASCADE;
CREATE TABLE silver.crm_opportunities AS
SELECT
    TRIM(opportunity_id)                                     AS opportunity_id,
    TRIM(name)                                                AS name,
    TRIM(stage)                                               AS stage,
    amount::NUMERIC(14, 2)                                    AS amount,
    close_date::DATE                                          AS close_date_estimada,
    created_at::TIMESTAMP                                     AS created_at,
    TRIM(account_id)                                          AS account_id,
    COALESCE(close_date::DATE < created_at::DATE, FALSE)      AS _dq_close_before_created,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'                                  AS _silver_loaded_at
FROM bronze.crm_opportunities;

ALTER TABLE silver.crm_opportunities ADD PRIMARY KEY (opportunity_id);

-- ---------------------------------------------------------------------------
-- opportunity_contacts: tabla puente, sin PK propia en origen. Sin
-- duplicados ni huérfanos (docs/decisiones.md §2.2 y §2.4). Solo tipado.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.crm_opportunity_contacts CASCADE;
CREATE TABLE silver.crm_opportunity_contacts AS
SELECT
    TRIM(opportunity_id)          AS opportunity_id,
    TRIM(contact_id)              AS contact_id,
    TRIM(role)                    AS role,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'      AS _silver_loaded_at
FROM bronze.crm_opportunity_contacts;

ALTER TABLE silver.crm_opportunity_contacts
    ADD PRIMARY KEY (opportunity_id, contact_id);

-- ---------------------------------------------------------------------------
-- activities: contact_id/opportunity_id nulos por diseño (una actividad se
-- asocia a uno u otro, no a ambos; docs/decisiones.md §2.1) — no se fuerza
-- NOT NULL. 18,4% / 37,8% ocurrida antes de la creación del contacto /
-- oportunidad asociada — se marca (docs/decisiones.md §2.5 y §2.6).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.crm_activities CASCADE;
CREATE TABLE silver.crm_activities AS
SELECT
    TRIM(a.activity_id)                                       AS activity_id,
    TRIM(a.type)                                              AS type,
    TRIM(a.subject)                                             AS subject,
    a.occurred_at::TIMESTAMP                                   AS occurred_at,
    TRIM(a.contact_id)                                         AS contact_id,
    TRIM(a.opportunity_id)                                     AS opportunity_id,
    COALESCE(
        a.contact_id IS NOT NULL
        AND ct.contact_id IS NOT NULL
        AND a.occurred_at::TIMESTAMP < ct.created_at::TIMESTAMP,
        FALSE
    )                                                          AS _dq_occurred_before_contact,
    COALESCE(
        a.opportunity_id IS NOT NULL
        AND o.opportunity_id IS NOT NULL
        AND a.occurred_at::TIMESTAMP < o.created_at::TIMESTAMP,
        FALSE
    )                                                          AS _dq_occurred_before_opportunity,
    a._source_domain,
    a._source_file,
    a._ingested_at,
    now() AT TIME ZONE 'UTC'                                  AS _silver_loaded_at
FROM bronze.crm_activities a
LEFT JOIN bronze.crm_contacts ct
    ON ct.contact_id = a.contact_id
LEFT JOIN bronze.crm_opportunities o
    ON o.opportunity_id = a.opportunity_id;

ALTER TABLE silver.crm_activities ADD PRIMARY KEY (activity_id);

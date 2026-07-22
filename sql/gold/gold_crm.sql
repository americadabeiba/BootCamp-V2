-- Gold — estrella crm + mart_leads
-- Justificación del diseño: docs/decisiones.md, sección "5. Modelado Gold".
-- Dos hechos separados (oportunidades vs. actividades): "cuánto vendo" y
-- "cuánto contacto genero" son preguntas de negocio distintas.
-- leads no tiene hecho ni dimensión propia: es mart_leads, una tabla analítica
-- aislada conectada solo a dim_fecha (confirmado: 0% de match hacia contacts,
-- docs/decisiones.md §1.3).

CREATE SCHEMA IF NOT EXISTS gold;

-- ---------------------------------------------------------------------------
-- dim_cuenta: se agrega name_occurrence_count (informativo, no booleano) para
-- que Gold sepa qué cuentas comparten nombre con otras (docs/decisiones.md
-- §2.2 — no son duplicados, son empresas distintas, pero es útil saber que
-- el nombre no es único).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dim_cuenta CASCADE;
CREATE TABLE gold.dim_cuenta AS
SELECT
    ROW_NUMBER() OVER (ORDER BY account_id)   AS cuenta_key,
    account_id,
    name                                        AS nombre,
    industry                                    AS industria,
    country                                     AS pais,
    annual_revenue                              AS ingresos_anuales,
    employees                                   AS empleados,
    created_at                                  AS fecha_alta,
    name_occurrence_count
FROM silver.crm_accounts;

ALTER TABLE gold.dim_cuenta ADD PRIMARY KEY (cuenta_key);
CREATE UNIQUE INDEX ON gold.dim_cuenta (account_id);

-- ---------------------------------------------------------------------------
-- dim_contacto: referencia a dim_cuenta (outrigger — un contacto pertenece a
-- una cuenta, no es snowflaking del hecho).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dim_contacto CASCADE;
CREATE TABLE gold.dim_contacto AS
SELECT
    ROW_NUMBER() OVER (ORDER BY ct.contact_id) AS contacto_key,
    ct.contact_id,
    ct.first_name                               AS nombre,
    ct.last_name                                AS apellido,
    ct.email,
    ct.phone                                    AS telefono,
    ct.title                                     AS cargo,
    ct.created_at                               AS fecha_alta,
    cu.cuenta_key,
    ct._dq_created_before_account
FROM silver.crm_contacts ct
JOIN gold.dim_cuenta cu ON cu.account_id = ct.account_id;

ALTER TABLE gold.dim_contacto ADD PRIMARY KEY (contacto_key);
CREATE UNIQUE INDEX ON gold.dim_contacto (contact_id);
ALTER TABLE gold.dim_contacto
    ADD FOREIGN KEY (cuenta_key) REFERENCES gold.dim_cuenta (cuenta_key);

-- ---------------------------------------------------------------------------
-- fact_oportunidades: grano = 1 fila por opportunity_id. Medida: amount
-- (no aditiva de forma trivial entre stages abiertos/cerrados — ver
-- docs/decisiones.md antes de sumarla sin filtrar por stage).
-- fecha_cierre_estimada_key usa close_date_estimada (reinterpretada en
-- docs/decisiones.md §2.6: es una fecha objetivo, no un cierre real).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_oportunidades CASCADE;
CREATE TABLE gold.fact_oportunidades AS
SELECT
    o.opportunity_id,
    cu.cuenta_key,
    fc.fecha_key                               AS fecha_creacion_key,
    fe.fecha_key                                AS fecha_cierre_estimada_key,
    o.amount,
    o.stage                                     AS etapa,
    o._dq_close_before_created
FROM silver.crm_opportunities o
JOIN gold.dim_cuenta cu ON cu.account_id = o.account_id
JOIN gold.dim_fecha fc ON fc.fecha = o.created_at::DATE
LEFT JOIN gold.dim_fecha fe ON fe.fecha = o.close_date_estimada;

ALTER TABLE gold.fact_oportunidades ADD PRIMARY KEY (opportunity_id);
ALTER TABLE gold.fact_oportunidades
    ADD FOREIGN KEY (cuenta_key) REFERENCES gold.dim_cuenta (cuenta_key),
    ADD FOREIGN KEY (fecha_creacion_key) REFERENCES gold.dim_fecha (fecha_key),
    ADD FOREIGN KEY (fecha_cierre_estimada_key) REFERENCES gold.dim_fecha (fecha_key);
CREATE INDEX ON gold.fact_oportunidades (fecha_creacion_key);

-- ---------------------------------------------------------------------------
-- fact_actividades: grano = 1 fila por activity_id. contacto_key y
-- opportunity_id nulos por diseño (una actividad se asocia a uno u otro, no
-- necesariamente a ambos; docs/decisiones.md §2.1). opportunity_id referencia
-- fact_oportunidades directamente (patrón encabezado-detalle).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_actividades CASCADE;
CREATE TABLE gold.fact_actividades AS
SELECT
    a.activity_id,
    ct.contacto_key,
    a.opportunity_id,
    fo.fecha_key                               AS fecha_ocurrencia_key,
    a.type                                       AS tipo,
    a.subject                                    AS asunto,
    a._dq_occurred_before_contact,
    a._dq_occurred_before_opportunity
FROM silver.crm_activities a
LEFT JOIN gold.dim_contacto ct ON ct.contact_id = a.contact_id
JOIN gold.dim_fecha fo ON fo.fecha = a.occurred_at::DATE;

ALTER TABLE gold.fact_actividades ADD PRIMARY KEY (activity_id);
ALTER TABLE gold.fact_actividades
    ADD FOREIGN KEY (contacto_key) REFERENCES gold.dim_contacto (contacto_key),
    ADD FOREIGN KEY (opportunity_id) REFERENCES gold.fact_oportunidades (opportunity_id),
    ADD FOREIGN KEY (fecha_ocurrencia_key) REFERENCES gold.dim_fecha (fecha_key);
CREATE INDEX ON gold.fact_actividades (fecha_ocurrencia_key);

-- ---------------------------------------------------------------------------
-- mart_leads: tabla analítica aislada (no es estrella: sin FK hacia
-- contacts/accounts/opportunities por diseño — docs/decisiones.md §1.3). Solo
-- se conecta a dim_fecha, para responder "cuántos leads entraron/se
-- perdieron en tal período" agrupando por fecha_creacion/source/status.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.mart_leads CASCADE;
CREATE TABLE gold.mart_leads AS
SELECT
    l.lead_id,
    l.first_name                               AS nombre,
    l.last_name                                 AS apellido,
    l.email,
    l.source                                    AS origen,
    l.status                                    AS estado,
    l.score                                      AS puntaje,
    fc.fecha_key                                AS fecha_creacion_key
FROM silver.crm_leads l
JOIN gold.dim_fecha fc ON fc.fecha = l.created_at::DATE;

ALTER TABLE gold.mart_leads ADD PRIMARY KEY (lead_id);
ALTER TABLE gold.mart_leads
    ADD FOREIGN KEY (fecha_creacion_key) REFERENCES gold.dim_fecha (fecha_key);

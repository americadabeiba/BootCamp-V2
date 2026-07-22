CREATE SCHEMA IF NOT EXISTS gold;

-- dim_cuenta
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

-- dim_contacto
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

-- fact_oportunidades
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

-- fact_actividades
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

-- mart_leads
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

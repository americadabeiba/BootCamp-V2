CREATE SCHEMA IF NOT EXISTS gold;

DROP TABLE IF EXISTS gold.kpi_tasa_aprobacion_curso CASCADE;
CREATE TABLE gold.kpi_tasa_aprobacion_curso AS
SELECT
    c.curso_key,
    c.codigo,
    c.nombre,
    COUNT(*) FILTER (WHERE f.status IN ('completed', 'failed'))     AS inscripciones_finalizadas,
    COUNT(*) FILTER (WHERE f.status = 'completed')                  AS aprobadas,
    COUNT(*) FILTER (WHERE f.status = 'failed')                     AS reprobadas,
    ROUND(
        COUNT(*) FILTER (WHERE f.status = 'completed')::NUMERIC
        / NULLIF(COUNT(*) FILTER (WHERE f.status IN ('completed', 'failed')), 0),
        4
    )                                                                AS tasa_aprobacion
FROM gold.dim_curso c
JOIN gold.fact_inscripciones f ON f.curso_key = c.curso_key
GROUP BY c.curso_key, c.codigo, c.nombre;

ALTER TABLE gold.kpi_tasa_aprobacion_curso ADD PRIMARY KEY (curso_key);

DROP TABLE IF EXISTS gold.kpi_tasa_aprobacion_semestre CASCADE;
CREATE TABLE gold.kpi_tasa_aprobacion_semestre AS
SELECT
    s.semestre_key,
    s.codigo,
    s.anio,
    s.periodo,
    COUNT(*) FILTER (WHERE f.status IN ('completed', 'failed'))     AS inscripciones_finalizadas,
    COUNT(*) FILTER (WHERE f.status = 'completed')                  AS aprobadas,
    COUNT(*) FILTER (WHERE f.status = 'failed')                     AS reprobadas,
    ROUND(
        COUNT(*) FILTER (WHERE f.status = 'completed')::NUMERIC
        / NULLIF(COUNT(*) FILTER (WHERE f.status IN ('completed', 'failed')), 0),
        4
    )                                                                AS tasa_aprobacion
FROM gold.dim_semestre s
JOIN gold.fact_inscripciones f ON f.semestre_key = s.semestre_key
GROUP BY s.semestre_key, s.codigo, s.anio, s.periodo;

ALTER TABLE gold.kpi_tasa_aprobacion_semestre ADD PRIMARY KEY (semestre_key);

DROP TABLE IF EXISTS gold.kpi_promedio_notas_tipo_evaluacion CASCADE;
CREATE TABLE gold.kpi_promedio_notas_tipo_evaluacion AS
SELECT
    te.tipo_evaluacion_key,
    te.tipo_evaluacion,
    COUNT(*)                       AS num_notas,
    ROUND(AVG(n.score), 2)         AS score_promedio,
    ROUND(AVG(n.weight), 2)        AS weight_promedio
FROM gold.dim_tipo_evaluacion te
JOIN gold.fact_notas n ON n.tipo_evaluacion_key = te.tipo_evaluacion_key
GROUP BY te.tipo_evaluacion_key, te.tipo_evaluacion;

ALTER TABLE gold.kpi_promedio_notas_tipo_evaluacion ADD PRIMARY KEY (tipo_evaluacion_key);

DROP TABLE IF EXISTS gold.kpi_estudiantes_en_riesgo CASCADE;
CREATE TABLE gold.kpi_estudiantes_en_riesgo AS
SELECT
    e.estudiante_key,
    e.student_id,
    e.nombre,
    e.apellido,
    COUNT(*) FILTER (WHERE f.status = 'failed')                     AS cursos_reprobados,
    COUNT(*) FILTER (WHERE f.status IN ('completed', 'failed'))     AS cursos_finalizados,
    ROUND(
        COUNT(*) FILTER (WHERE f.status = 'failed')::NUMERIC
        / NULLIF(COUNT(*) FILTER (WHERE f.status IN ('completed', 'failed')), 0),
        4
    )                                                                AS tasa_reprobacion
FROM gold.dim_estudiante e
JOIN gold.fact_inscripciones f ON f.estudiante_key = e.estudiante_key
GROUP BY e.estudiante_key, e.student_id, e.nombre, e.apellido
HAVING COUNT(*) FILTER (WHERE f.status = 'failed') > 0;

ALTER TABLE gold.kpi_estudiantes_en_riesgo ADD PRIMARY KEY (estudiante_key);

DROP TABLE IF EXISTS gold.kpi_facturacion_mensual CASCADE;
CREATE TABLE gold.kpi_facturacion_mensual AS
SELECT
    fe.anio,
    fe.mes,
    COUNT(DISTINCT i.invoice_id)   AS num_facturas,
    SUM(i.total)                   AS total_facturado,
    MAX(pagos.total_cobrado)       AS total_cobrado
FROM gold.fact_facturas i
JOIN gold.dim_fecha fe ON fe.fecha_key = i.fecha_emision_key
LEFT JOIN (
    SELECT fp.anio, fp.mes, SUM(p.amount) AS total_cobrado
    FROM gold.fact_pagos p
    JOIN gold.dim_fecha fp ON fp.fecha_key = p.fecha_pago_key
    GROUP BY fp.anio, fp.mes
) pagos ON pagos.anio = fe.anio AND pagos.mes = fe.mes
GROUP BY fe.anio, fe.mes;

ALTER TABLE gold.kpi_facturacion_mensual ADD PRIMARY KEY (anio, mes);

DROP TABLE IF EXISTS gold.kpi_mrr_producto CASCADE;
CREATE TABLE gold.kpi_mrr_producto AS
SELECT
    p.producto_key,
    p.sku,
    p.nombre,
    p.precio_mensual,
    COUNT(*)                                   AS suscripciones_activas,
    ROUND(COUNT(*) * p.precio_mensual, 2)      AS mrr_aproximado
FROM gold.dim_producto p
JOIN gold.fact_suscripciones s
    ON s.producto_key = p.producto_key AND s.status = 'active'
GROUP BY p.producto_key, p.sku, p.nombre, p.precio_mensual;

ALTER TABLE gold.kpi_mrr_producto ADD PRIMARY KEY (producto_key);

DROP TABLE IF EXISTS gold.kpi_suscripciones_vencidas CASCADE;
CREATE TABLE gold.kpi_suscripciones_vencidas AS
SELECT
    s.subscription_id,
    s.cliente_key,
    s.producto_key,
    fd.fecha                       AS fecha_fin,
    CURRENT_DATE - fd.fecha        AS dias_vencida
FROM gold.fact_suscripciones s
JOIN gold.dim_fecha fd ON fd.fecha_key = s.fecha_fin_key
WHERE s.status = 'active' AND fd.fecha < CURRENT_DATE;

ALTER TABLE gold.kpi_suscripciones_vencidas ADD PRIMARY KEY (subscription_id);

DROP TABLE IF EXISTS gold.kpi_pipeline_oportunidades CASCADE;
CREATE TABLE gold.kpi_pipeline_oportunidades AS
SELECT
    etapa,
    COUNT(*)                AS num_oportunidades,
    SUM(amount)              AS monto_total,
    ROUND(AVG(amount), 2)    AS monto_promedio
FROM gold.fact_oportunidades
GROUP BY etapa;

ALTER TABLE gold.kpi_pipeline_oportunidades ADD PRIMARY KEY (etapa);

DROP TABLE IF EXISTS gold.kpi_tasa_cierre_oportunidades CASCADE;
CREATE TABLE gold.kpi_tasa_cierre_oportunidades AS
SELECT
    COUNT(*) FILTER (WHERE etapa = 'won')      AS ganadas,
    COUNT(*) FILTER (WHERE etapa = 'lost')     AS perdidas,
    ROUND(
        COUNT(*) FILTER (WHERE etapa = 'won')::NUMERIC
        / NULLIF(COUNT(*) FILTER (WHERE etapa IN ('won', 'lost')), 0),
        4
    )                                            AS tasa_cierre_ganado
FROM gold.fact_oportunidades;

DROP TABLE IF EXISTS gold.kpi_engagement_cuenta CASCADE;
CREATE TABLE gold.kpi_engagement_cuenta AS
SELECT
    cu.cuenta_key,
    cu.account_id,
    cu.nombre,
    COALESCE(ct.num_contactos, 0)       AS num_contactos,
    COALESCE(op.num_oportunidades, 0)   AS num_oportunidades,
    COALESCE(op.monto_pipeline, 0)      AS monto_pipeline,
    COALESCE(ac.num_actividades, 0)     AS num_actividades
FROM gold.dim_cuenta cu
LEFT JOIN (
    SELECT cuenta_key, COUNT(*) AS num_contactos
    FROM gold.dim_contacto
    GROUP BY cuenta_key
) ct ON ct.cuenta_key = cu.cuenta_key
LEFT JOIN (
    SELECT cuenta_key, COUNT(*) AS num_oportunidades, SUM(amount) AS monto_pipeline
    FROM gold.fact_oportunidades
    GROUP BY cuenta_key
) op ON op.cuenta_key = cu.cuenta_key
LEFT JOIN (
    SELECT COALESCE(co.cuenta_key, o.cuenta_key) AS cuenta_key, COUNT(*) AS num_actividades
    FROM gold.fact_actividades a
    LEFT JOIN gold.dim_contacto co ON co.contacto_key = a.contacto_key
    LEFT JOIN gold.fact_oportunidades o ON o.opportunity_id = a.opportunity_id
    WHERE co.cuenta_key IS NOT NULL OR o.cuenta_key IS NOT NULL
    GROUP BY COALESCE(co.cuenta_key, o.cuenta_key)
) ac ON ac.cuenta_key = cu.cuenta_key;

ALTER TABLE gold.kpi_engagement_cuenta ADD PRIMARY KEY (cuenta_key);

DROP TABLE IF EXISTS gold.kpi_conversion_leads CASCADE;
CREATE TABLE gold.kpi_conversion_leads AS
SELECT
    origen,
    COUNT(*)                                                    AS total_leads,
    COUNT(*) FILTER (WHERE estado = 'converted')                AS convertidos,
    COUNT(*) FILTER (WHERE estado = 'lost')                      AS perdidos,
    ROUND(COUNT(*) FILTER (WHERE estado = 'converted')::NUMERIC / COUNT(*), 4) AS tasa_conversion,
    ROUND(AVG(puntaje), 2)                                       AS puntaje_promedio
FROM gold.mart_leads
GROUP BY origen;

ALTER TABLE gold.kpi_conversion_leads ADD PRIMARY KEY (origen);

DROP TABLE IF EXISTS gold.kpi_facturacion_estudiantes CASCADE;
CREATE TABLE gold.kpi_facturacion_estudiantes AS
SELECT
    e.estudiante_key,
    e.student_id,
    e.nombre,
    e.apellido,
    cl.cliente_key,
    COALESCE(fact.num_facturas, 0)          AS num_facturas,
    COALESCE(fact.total_facturado, 0)       AS total_facturado,
    COALESCE(insc.num_cursos_inscritos, 0)  AS num_cursos_inscritos,
    COALESCE(insc.num_cursos_aprobados, 0)  AS num_cursos_aprobados
FROM gold.dim_estudiante e
JOIN gold.dim_cliente cl ON cl.external_ref = e.student_id
LEFT JOIN (
    SELECT cliente_key, COUNT(*) AS num_facturas, SUM(total) AS total_facturado
    FROM gold.fact_facturas
    GROUP BY cliente_key
) fact ON fact.cliente_key = cl.cliente_key
LEFT JOIN (
    SELECT
        estudiante_key,
        COUNT(*)                                       AS num_cursos_inscritos,
        COUNT(*) FILTER (WHERE status = 'completed')   AS num_cursos_aprobados
    FROM gold.fact_inscripciones
    GROUP BY estudiante_key
) insc ON insc.estudiante_key = e.estudiante_key;

ALTER TABLE gold.kpi_facturacion_estudiantes ADD PRIMARY KEY (estudiante_key);
ALTER TABLE gold.kpi_facturacion_estudiantes
    ADD FOREIGN KEY (cliente_key) REFERENCES gold.dim_cliente (cliente_key);

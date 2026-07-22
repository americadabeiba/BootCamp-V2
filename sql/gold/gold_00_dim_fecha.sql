CREATE SCHEMA IF NOT EXISTS gold;

DROP TABLE IF EXISTS gold.dim_fecha CASCADE;
CREATE TABLE gold.dim_fecha AS
SELECT
    (EXTRACT(YEAR FROM d)::INT * 10000
        + EXTRACT(MONTH FROM d)::INT * 100
        + EXTRACT(DAY FROM d)::INT)        AS fecha_key,
    d::DATE                                AS fecha,
    EXTRACT(YEAR FROM d)::INT              AS anio,
    EXTRACT(MONTH FROM d)::INT             AS mes,
    TRIM(TO_CHAR(d, 'TMMonth'))            AS nombre_mes,
    EXTRACT(DAY FROM d)::INT               AS dia,
    EXTRACT(QUARTER FROM d)::INT           AS trimestre,
    EXTRACT(ISODOW FROM d)::INT            AS dia_semana_iso,
    TRIM(TO_CHAR(d, 'TMDay'))              AS nombre_dia_semana,
    (EXTRACT(ISODOW FROM d) IN (6, 7))     AS es_fin_de_semana,
    EXTRACT(WEEK FROM d)::INT              AS semana_anio
FROM generate_series('2015-01-01'::DATE, '2035-12-31'::DATE, INTERVAL '1 day') AS d;

ALTER TABLE gold.dim_fecha ADD PRIMARY KEY (fecha_key);
CREATE UNIQUE INDEX ON gold.dim_fecha (fecha);

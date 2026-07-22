CREATE SCHEMA IF NOT EXISTS gold;

-- dim_cliente
DROP TABLE IF EXISTS gold.dim_cliente CASCADE;
CREATE TABLE gold.dim_cliente AS
SELECT
    ROW_NUMBER() OVER (ORDER BY customer_id)  AS cliente_key,
    customer_id,
    external_ref,
    first_name                                 AS nombre,
    last_name                                  AS apellido,
    email,
    country                                    AS pais,
    created_at                                 AS fecha_alta,
    segment                                    AS segmento,
    _dq_country_mismatch_university
FROM silver.billing_customers;

ALTER TABLE gold.dim_cliente ADD PRIMARY KEY (cliente_key);
CREATE UNIQUE INDEX ON gold.dim_cliente (customer_id);
ALTER TABLE gold.dim_cliente
    ADD FOREIGN KEY (external_ref) REFERENCES gold.dim_estudiante (student_id);

-- dim_producto
DROP TABLE IF EXISTS gold.dim_producto CASCADE;
CREATE TABLE gold.dim_producto AS
SELECT
    ROW_NUMBER() OVER (ORDER BY product_id)   AS producto_key,
    product_id,
    sku,
    name                                        AS nombre,
    category                                    AS categoria,
    monthly_price                               AS precio_mensual,
    active                                      AS activo
FROM silver.billing_products;

ALTER TABLE gold.dim_producto ADD PRIMARY KEY (producto_key);
CREATE UNIQUE INDEX ON gold.dim_producto (product_id);

-- fact_suscripciones
DROP TABLE IF EXISTS gold.fact_suscripciones CASCADE;
CREATE TABLE gold.fact_suscripciones AS
SELECT
    s.subscription_id,
    cl.cliente_key,
    pr.producto_key,
    fi.fecha_key                               AS fecha_inicio_key,
    ff.fecha_key                                AS fecha_fin_key,
    s.status,
    s._dq_start_after_end
FROM silver.billing_subscriptions s
JOIN gold.dim_cliente cl ON cl.customer_id = s.customer_id
JOIN gold.dim_producto pr ON pr.product_id = s.product_id
JOIN gold.dim_fecha fi ON fi.fecha = s.start_date
LEFT JOIN gold.dim_fecha ff ON ff.fecha = s.end_date;

ALTER TABLE gold.fact_suscripciones ADD PRIMARY KEY (subscription_id);
ALTER TABLE gold.fact_suscripciones
    ADD FOREIGN KEY (cliente_key) REFERENCES gold.dim_cliente (cliente_key),
    ADD FOREIGN KEY (producto_key) REFERENCES gold.dim_producto (producto_key),
    ADD FOREIGN KEY (fecha_inicio_key) REFERENCES gold.dim_fecha (fecha_key),
    ADD FOREIGN KEY (fecha_fin_key) REFERENCES gold.dim_fecha (fecha_key);

-- fact_facturas
DROP TABLE IF EXISTS gold.fact_facturas CASCADE;
CREATE TABLE gold.fact_facturas AS
SELECT
    i.invoice_id,
    cl.cliente_key,
    fi.fecha_key                               AS fecha_emision_key,
    fd.fecha_key                                AS fecha_vencimiento_key,
    i.total,
    i.status,
    i.currency                                  AS moneda,
    i._dq_total_mismatch_items
FROM silver.billing_invoices i
JOIN gold.dim_cliente cl ON cl.customer_id = i.customer_id
JOIN gold.dim_fecha fi ON fi.fecha = i.issued_at
LEFT JOIN gold.dim_fecha fd ON fd.fecha = i.due_at;

ALTER TABLE gold.fact_facturas ADD PRIMARY KEY (invoice_id);
ALTER TABLE gold.fact_facturas
    ADD FOREIGN KEY (cliente_key) REFERENCES gold.dim_cliente (cliente_key),
    ADD FOREIGN KEY (fecha_emision_key) REFERENCES gold.dim_fecha (fecha_key),
    ADD FOREIGN KEY (fecha_vencimiento_key) REFERENCES gold.dim_fecha (fecha_key);
CREATE INDEX ON gold.fact_facturas (fecha_emision_key);

-- fact_pagos
DROP TABLE IF EXISTS gold.fact_pagos CASCADE;
CREATE TABLE gold.fact_pagos AS
SELECT
    p.payment_id,
    p.invoice_id,
    fp.fecha_key                               AS fecha_pago_key,
    p.amount,
    p.method                                    AS metodo
FROM silver.billing_payments p
JOIN gold.dim_fecha fp ON fp.fecha = p.paid_at;

ALTER TABLE gold.fact_pagos ADD PRIMARY KEY (payment_id);
ALTER TABLE gold.fact_pagos
    ADD FOREIGN KEY (invoice_id) REFERENCES gold.fact_facturas (invoice_id),
    ADD FOREIGN KEY (fecha_pago_key) REFERENCES gold.dim_fecha (fecha_key);
CREATE INDEX ON gold.fact_pagos (invoice_id);

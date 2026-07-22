CREATE SCHEMA IF NOT EXISTS silver;


-- customers
DROP TABLE IF EXISTS silver.billing_customers CASCADE;
CREATE TABLE silver.billing_customers AS
SELECT
    TRIM(c.customer_id)                                     AS customer_id,
    TRIM(c.external_ref)                                    AS external_ref,
    TRIM(c.first_name)                                      AS first_name,
    TRIM(c.last_name)                                       AS last_name,
    LOWER(TRIM(c.email))                                    AS email,
    TRIM(c.country)                                          AS country,
    c.created_at::TIMESTAMP                                  AS created_at,
    TRIM(c.segment)                                          AS segment,
    COALESCE(s.country IS NOT NULL AND s.country <> c.country, FALSE)
                                                              AS _dq_country_mismatch_university,
    c._source_domain,
    c._source_file,
    c._ingested_at,
    now() AT TIME ZONE 'UTC'                                 AS _silver_loaded_at
FROM bronze.billing_customers c
LEFT JOIN bronze.university_students s
    ON s.student_id = c.external_ref;

ALTER TABLE silver.billing_customers ADD PRIMARY KEY (customer_id);


-- products
DROP TABLE IF EXISTS silver.billing_products CASCADE;
CREATE TABLE silver.billing_products AS
SELECT
    TRIM(product_id)              AS product_id,
    TRIM(sku)                     AS sku,
    TRIM(name)                    AS name,
    TRIM(category)                AS category,
    monthly_price::NUMERIC(14, 2) AS monthly_price,
    active,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'      AS _silver_loaded_at
FROM bronze.billing_products;

ALTER TABLE silver.billing_products ADD PRIMARY KEY (product_id);

-- subscriptions
DROP TABLE IF EXISTS silver.billing_subscriptions CASCADE;
CREATE TABLE silver.billing_subscriptions AS
SELECT
    TRIM(subscription_id)                                   AS subscription_id,
    TRIM(status)                                             AS status,
    start_date::DATE                                         AS start_date,
    end_date::DATE                                           AS end_date,
    TRIM(customer_id)                                        AS customer_id,
    TRIM(product_id)                                         AS product_id,
    COALESCE(start_date::DATE >= end_date::DATE, FALSE)      AS _dq_start_after_end,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'                                 AS _silver_loaded_at
FROM bronze.billing_subscriptions;

ALTER TABLE silver.billing_subscriptions ADD PRIMARY KEY (subscription_id);

-- invoices
DROP TABLE IF EXISTS silver.billing_invoices CASCADE;
CREATE TABLE silver.billing_invoices AS
SELECT
    TRIM(i.invoice_id)                                       AS invoice_id,
    i.issued_at::DATE                                        AS issued_at,
    i.due_at::DATE                                           AS due_at,
    i.total::NUMERIC(14, 2)                                  AS total,
    TRIM(i.status)                                           AS status,
    TRIM(i.currency)                                          AS currency,
    TRIM(i.customer_id)                                       AS customer_id,
    COALESCE(
        ABS(i.total::NUMERIC(14, 2) - COALESCE(it.items_total, 0)) > 0.01,
        FALSE
    )                                                        AS _dq_total_mismatch_items,
    i._source_domain,
    i._source_file,
    i._ingested_at,
    now() AT TIME ZONE 'UTC'                                AS _silver_loaded_at
FROM bronze.billing_invoices i
LEFT JOIN (
    SELECT invoice_id, SUM(line_total::NUMERIC(14, 2)) AS items_total
    FROM bronze.billing_invoice_items
    GROUP BY invoice_id
) it ON it.invoice_id = i.invoice_id;

ALTER TABLE silver.billing_invoices ADD PRIMARY KEY (invoice_id);

-- invoice_items
DROP TABLE IF EXISTS silver.billing_invoice_items CASCADE;
CREATE TABLE silver.billing_invoice_items AS
SELECT
    TRIM(invoice_item_id)         AS invoice_item_id,
    quantity::INTEGER              AS quantity,
    unit_price::NUMERIC(14, 2)    AS unit_price,
    line_total::NUMERIC(14, 2)    AS line_total,
    TRIM(invoice_id)               AS invoice_id,
    TRIM(product_id)               AS product_id,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'      AS _silver_loaded_at
FROM bronze.billing_invoice_items;

ALTER TABLE silver.billing_invoice_items ADD PRIMARY KEY (invoice_item_id);

-- payments
DROP TABLE IF EXISTS silver.billing_payments CASCADE;
CREATE TABLE silver.billing_payments AS
SELECT
    TRIM(payment_id)              AS payment_id,
    amount::NUMERIC(14, 2)        AS amount,
    paid_at::DATE                 AS paid_at,
    TRIM(method)                   AS method,
    TRIM(invoice_id)                AS invoice_id,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'      AS _silver_loaded_at
FROM bronze.billing_payments;

ALTER TABLE silver.billing_payments ADD PRIMARY KEY (payment_id);

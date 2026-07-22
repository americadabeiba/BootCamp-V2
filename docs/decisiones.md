# Decisiones del proyecto

Documento único de decisiones, hallazgos de calidad y reglas aplicadas. Todo lo que
antes vivía en `docs/hallazgos_calidad.md` se movió aquí (se eliminó ese archivo);
de aquí en adelante toda decisión y todo hallazgo se documenta **solo en este
archivo**.

---

## 1. Relaciones entre dominios (Bronze)

### 1.1 Vínculo university ↔ billing
- `billing.customers.external_ref` coincide en formato y valor con
  `bronze.university_students.student_id`.
- `students` = 5.000, `customers` = 10.000 → como máximo el 50% de los customers
  puede tener estudiante asociado.
- Verificado contra datos reales: **5.000 de 5.000 `external_ref` no nulos matchean**
  un `student_id` real (0 huérfanos); la relación es 1:1 (`external_ref` no se repite
  entre customers).
- País y nombre **no coinciden** entre el student y el customer vinculado en el 78,6%
  de los casos (3.928 de 5.000 pares) — ver detalle cuantitativo en §2.4. Hipótesis:
  dato generado de forma independiente por tabla (seed=42, generador sintético), no
  necesariamente una persona distinta (tutor/representante). Pendiente de verificar
  con muestra manual; no bloquea el uso de `external_ref` como llave de integración,
  pero si se traen atributos (país, nombre) desde `students` hacia `customers` en
  Silver/Gold, debe quedar explícito que son dos registros de fuentes distintas y
  pueden no describir a la misma persona.

### 1.2 CRM sin llave hacia billing/university
- No existe columna compartida entre `accounts`/`opportunities` y
  `customers`/`students`.
- `crm.contacts.email` ↔ `billing.customers.email`: verificado — solo **1 de 15.000**
  contactos matchea un email de `customers`. Confirma que **no hay** un join
  explotable por email entre CRM y Billing; cualquier vínculo tendría que
  construirse con señales indirectas (fechas, montos) y quedaría documentado como
  correlación, no como join verificado. No se modela en Silver.

### 1.3 Leads como tabla independiente
- No tiene FK hacia `accounts`/`contacts`/`opportunities` por diseño (representa
  pre-conversión).
- Verificado: **0 de 2.000** leads matchean un contacto existente por email → la
  conversión lead→contacto no es reconstruible con los datos disponibles.
- Decisión: se modela como mart de funnel de marketing aislado (tasa de conversión
  por `source`/`status`), sin intentar joinearlo a CRM/Billing en Silver.

---

## 2. Hallazgos de calidad de datos (Bronze)

Consolidado de lo obtenido en `notebooks/discovery_university.ipynb`,
`notebooks/discovery_billing.ipynb` y `notebooks/discovery_crm.ipynb`, ejecutados
contra `bronze.*`.

**Nota de reproducibilidad:** las validaciones que comparan contra `CURRENT_DATE`
(p. ej. suscripciones activas vencidas) son sensibles a la fecha de ejecución; los
conteos pueden variar levemente si se re-corren en otro momento.

### 2.1 Nulos

Ninguna de las 18 tablas Bronze presenta nulos en las columnas perfiladas, con dos
excepciones **esperadas por diseño**:

- `crm.activities.contact_id`: 5.976 de 20.000 filas (29,9%) nulas.
- `crm.activities.opportunity_id`: 9.985 de 20.000 filas (49,9%) nulas.

Una actividad se asocia a un contacto **o** a una oportunidad, no necesariamente a
ambos → no se tratan como defecto ni se fuerza `NOT NULL` en Silver.

**Detalle verificado sobre `silver.crm_activities` (no estaba cuantificado
antes de esta revisión):** la relación no es una disyuntiva exclusiva. De las
20.000 actividades:

| Caso | Filas | % |
|---|---|---|
| Con contacto y sin oportunidad | 7.004 | 35,0% |
| Con oportunidad y sin contacto | 2.995 | 15,0% |
| Con ambos a la vez | 7.020 | 35,1% |
| Sin ninguno de los dos | 2.981 | 14,9% |

Los primeros dos casos ya estaban cubiertos por la redacción original ("uno u
otro"). Los otros dos no: **7.020 actividades (35,1%) están ligadas a un
contacto y a una oportunidad simultáneamente**, y **2.981 (14,9%) no tienen
ninguna de las dos referencias**. No es un error de join en Gold — se
verificó directamente sobre `silver.crm_activities`, antes de cualquier join.
No se conserva evidencia suficiente en el dataset para saber si el segundo
grupo (sin contacto ni oportunidad) corresponde a actividades a nivel de
cuenta que el generador de datos no etiquetó, o a un dato faltante real; se
deja como hallazgo abierto y no bloquea el modelado de `fact_actividades`
(ambas referencias ya son nullable por diseño, ver §5.1 y `sql/gold/gold_crm.sql`).

### 2.2 Duplicados

| Tabla | Hallazgo | Magnitud | Investigado |
|---|---|---|---|
| `university.professors` | Pares nombre+apellido repetidos, `professor_id` distinto | 6 pares | — |
| `university.students` | Ternas nombre+apellido+fecha nacimiento repetidas | 3 ternas | `student_id` y `email` distintos en cada terna → coincidencia del generador, no la misma persona dos veces |
| `university.enrollments` | Duplicados por clave de negocio (student+course+semester) | 23 pares | `enrollment_id` distinto, `status`/`enrolled_at` distintos en cada par (p. ej. `failed` vs `completed`, fechas ~1 año de diferencia) → son reintentos/retomas legítimas del mismo curso, no error de carga |
| `university.grades` | Duplicados por (enrollment_id + assessment) | **10.544 combinaciones (enrollment_id, assessment) con más de una nota**, de las cuales 8.954 tienen 2 notas, 1.417 tienen 3, 158 tienen 4, 14 tienen 5 y 1 tiene 6 → **12.323 filas excedentes en total (20,5% de 60.000)** | `score`/`graded_at` distintos entre las notas repetidas → sí son redundancia real (múltiples notas del mismo tipo para la misma inscripción); es la causa más probable de que 22.104 enrollments tengan suma de `weight` fuera de rango (ver §2.5) |
| `billing.customers` | Email duplicado | 0 | — |
| `billing.products` | SKU duplicado | 0 | — |
| `billing.invoice_items` | Mismo producto repetido en la misma factura (invoice_id+product_id) | 1.103 pares | Escenario de negocio válido (dos líneas del mismo producto en momentos distintos de la factura) |
| `crm.accounts` | Nombre de cuenta repetido | 599 nombres, hasta 19 repeticiones (p. ej. "Patagonia Labs") | `industry`/`country` **distintos** en cada `account_id` repetido → son empresas distintas que coinciden en nombre por el generador sintético (pool de nombres limitado), **no son duplicados de la misma cuenta** |
| `crm.contacts` | Email duplicado | 2 | — |
| `crm.leads` | Email duplicado | 0 | — |
| `crm.opportunity_contacts` | Par (opportunity_id, contact_id) duplicado | 0 | — |

**Decisión de deduplicación** (aplicada en Silver, ver §4):
- `university.grades` → **sí se deduplica**, es redundancia real.
- `university.enrollments`, `university.students`, `crm.accounts` → **no se
  deduplican**: la evidencia (status/fechas distintos, industry/country distintos,
  email distinto) muestra que son entidades o eventos legítimamente distintos, no
  errores de carga. Deduplicar aquí destruiría información real.

### 2.3 Formatos inconsistentes

- Todas las columnas de fecha en texto fueron validadas con regex
  `^\d{4}-\d{2}-\d{2}` contra los 18 CSV: **0 filas con formato no parseable**. El
  formato de fecha es consistente (ISO `YYYY-MM-DD`, con hora en algunas columnas,
  ver §4 para el detalle de cuáles).
- `crm.activities.subject`: ratio de unicidad = 1.0 (20.000/20.000 valores
  distintos) — es texto libre, no una categoría.

### 2.4 Llaves huérfanas (integridad referencial)

Todas las FK explícitas dentro de cada dominio están limpias — **0 huérfanas** en:
`enrollments→students/courses/semesters`, `grades→enrollments`,
`subscriptions→customers/products`, `invoices→customers`,
`invoice_items→invoices/products`, `payments→invoices`, `contacts→accounts`,
`opportunities→accounts`, `opportunity_contacts→opportunities/contacts`,
`activities→contacts/opportunities` (sobre valores no nulos).

Huérfanos "débiles" (sin romper FK, pero sin actividad asociada):
- **38 estudiantes** sin ninguna inscripción en `enrollments`.

Detalle del vínculo university↔billing (referido en §1.1): de los 5.000 pares
customer↔student con `external_ref` matcheado, **solo 1.072 (21,4%) comparten el
mismo país**; 3.928 (78,6%) tienen país distinto entre el customer y el student.

### 2.5 Outliers e inconsistencias lógicas

#### University
- **264 de 300 cursos (88%)** son dictados por un profesor de un departamento
  distinto al del curso.
- **1.851 de 5.000 estudiantes (37%)** tienen `enrolled_at` (fecha de alta)
  posterior a su primera inscripción real en `enrollments`.
- **22.729 de 25.000 enrollments (91%)** tienen `enrolled_at` fuera del rango
  `[start_date, end_date]` del semestre asociado.
- **29.241 de 60.000 grades (48,7%)** tienen `graded_at` anterior a `enrolled_at` de
  su inscripción — cifra sobre el Bronze completo (antes de deduplicar). Sobre
  `silver.university_grades` ya deduplicado (47.677 filas), el conteo verificado de
  `_dq_graded_before_enrollment` es **21.386 (44,9%)** — baja porque parte de las
  filas removidas en la dedup (§2.2) eran justamente las notas con `graded_at` más
  antiguo, que es la condición que dispara este flag.
- **26.828 de 60.000 grades (44,7%)** tienen `graded_at` posterior al `end_date` del
  semestre correspondiente — cifra sobre Bronze. Sobre Silver ya deduplicado, el
  conteo verificado de `_dq_graded_after_semester_end` es **23.141 (48,5%)**.
- **22.104 enrollments** tienen la suma de `weight` de sus notas fuera del rango
  esperado (ni ~1 ni ~100) — parcialmente explicado por los duplicados de §2.2. Esta
  verificación es agregada (por `enrollment_id`) y no se materializó como columna en
  Silver; queda como consulta de validación a re-ejecutar sobre
  `silver.university_grades` antes de construir KPIs académicos en Gold.
- Rango de `score` correcto (24,53–100), sin valores fuera de `[0,100]`.

#### Billing
- **789 de 15.000 subscriptions (5,3%)** tienen `start_date >= end_date` (fechas
  invertidas).
- **7.154 de 15.000 subscriptions (47,7%)** están en estado `active` con `end_date`
  ya vencido respecto a la fecha de ejecución de la consulta.
- **49.999 de 50.000 invoices (~100%)** tienen `total` que **no** coincide con la
  suma de `invoice_items.line_total` asociados. Es el hallazgo más relevante de todo
  el dataset: `invoices.total` no es reconciliable con sus líneas en prácticamente
  ningún caso.
- La reconciliación `SUM(payments.amount)` vs `invoices.total` también muestra
  diferencias generalizadas en ambos sentidos.
- `invoice_items`: `line_total = quantity × unit_price` se cumple en el 100% de las
  150.000 filas — la inconsistencia está en `invoices.total`, no en las líneas.
- **Decisión:** `invoices.total` se mantiene como fuente de verdad de ingresos
  facturados (es el campo propio del sistema de billing); no se recalcula desde
  `invoice_items` ni desde `payments`. Cualquier métrica de Gold que necesite
  desglose por producto debe usar `invoice_items` explícitamente y **no** asumir
  que su suma reconstruye `invoices.total`.

#### CRM
- **7.451 de 15.000 contacts (49,7%)** tienen `created_at` anterior al `created_at`
  de su `account_id`. (En Silver, comparando con precisión de `TIMESTAMP` completo
  en vez de truncar a `::date` como en la notebook de discovery, el conteo exacto
  sube a **7.456** — 5 casos empatan en la fecha calendario pero difieren en la
  hora; ver `_dq_created_before_account` en `silver.crm_contacts`.)
- **1.029 de 3.000 opportunities (34,3%)** tienen `close_date` anterior a
  `created_at`.
- **2.579 de ~14.024 activities con `contact_id`** (18,4%) ocurrieron antes de la
  creación del contacto asociado (`_dq_occurred_before_contact` en Silver: mismo
  conteo, 2.579).
- **3.790 de ~10.015 activities con `opportunity_id`** (37,8%) ocurrieron antes de
  la creación de la oportunidad asociada. (En Silver, con precisión de `TIMESTAMP`
  completo, el conteo exacto es **3.792** — misma razón que en `contacts` arriba;
  ver `_dq_occurred_before_opportunity` en `silver.crm_activities`.)

### 2.6 Hallazgo nuevo: `bronze.crm_opportunities` — `close_date` vs `created_at`

Al revisar `close_date` con más detalle: **el 100% de las 3.000 oportunidades tiene
`close_date` no nulo**, incluidas las que están en etapas abiertas (`prospect`,
`qualification`, `proposal`, `negotiation`) y no solo las cerradas (`won`, `lost`).

Esto cambia la interpretación del campo: si `close_date` fuera "fecha real de
cierre", debería ser `NULL` mientras la oportunidad sigue abierta — no lo es nunca.
**Decisión: `close_date` se reinterpreta como fecha de cierre *estimada/objetivo*,
no como fecha real de cierre.** Bajo esa lectura, que el 34,3% de los casos tenga
`close_date` anterior a `created_at` sigue siendo una inconsistencia (una fecha
objetivo no debería fijarse antes de que la oportunidad exista), pero dejó de leerse
como "se cerró antes de abrirse". Esta reinterpretación se documenta en Silver
renombrando la columna a **`close_date_estimada`** en `silver.crm_opportunities`
(`sql/silver/silver_crm.sql`) para que nadie en Gold la use asumiendo que es una
fecha de cierre real; no calcular "días para cerrar" como
`close_date_estimada - created_at` sin dejar explícito que es una meta, no un
hecho.

**Regla general aplicada a partir de este hallazgo:** la misma lógica de validación
cronológica (¿la fecha B, que depende de la fecha A de otra tabla o de la misma fila,
es igual o posterior a A?) se aplicó sistemáticamente a **todas** las relaciones de
fecha entre tablas del dataset, no solo a `crm_opportunities`:

| Relación | Regla | Resultado |
|---|---|---|
| `university_enrollments.enrolled_at` vs `university_semesters.[start_date,end_date]` | debe caer dentro del rango del semestre | 91% fuera de rango (§2.5) |
| `university_grades.graded_at` vs `university_enrollments.enrolled_at` | la nota no puede ser anterior a la inscripción | 48,7% en Bronze / 44,9% en Silver deduplicado (§2.5) |
| `university_grades.graded_at` vs `university_semesters.end_date` | la nota no puede calificarse después de terminado el semestre | 44,7% en Bronze / 48,5% en Silver deduplicado (§2.5) |
| `university_students.enrolled_at` vs `MIN(enrollments.enrolled_at)` | el alta del estudiante no puede ser posterior a su primera inscripción | 37% inconsistente (§2.5) |
| `billing_subscriptions.start_date` vs `end_date` | inicio antes que fin | 5,3% inconsistente (§2.5) |
| `billing_invoices.issued_at` vs `due_at` | 0% inconsistente (validado, sin hallazgo) |
| `billing_payments.paid_at` vs `billing_invoices.issued_at` | el pago no puede ser anterior a la emisión | 0% inconsistente (validado, sin hallazgo) |
| `crm_contacts.created_at` vs `crm_accounts.created_at` | el contacto no puede crearse antes que su cuenta | 49,7% inconsistente (§2.5) |
| `crm_opportunities.close_date` vs `created_at` | ver reinterpretación arriba | 34,3% inconsistente |
| `crm_activities.occurred_at` vs `crm_contacts.created_at` | 18,4% inconsistente (§2.5) |
| `crm_activities.occurred_at` vs `crm_opportunities.created_at` | 37,8% inconsistente (§2.5) |

Todas estas reglas están implementadas como columnas de calidad (`_dq_*`) en las
tablas Silver correspondientes (§4) — se preservan las filas y se marcan, no se
eliminan (ver justificación de la política general en §3).

---

## 3. Por qué el Bronze exhaustivo importaba (respuesta a la reserva planteada)

La preocupación de fondo — duplicados, nulos y fechas inconsistentes pueden invalidar
buena parte del análisis si no se tratan explícitamente — es correcta y es
exactamente para eso que se hizo el perfilado exhaustivo en Bronze antes de tocar
Silver: **sin ese profiling no habríamos sabido que, por ejemplo, el 91% de las
inscripciones cae fuera del rango de su semestre, o que el 100% de las facturas no
reconcilia con sus líneas.** Son proporciones demasiado grandes para ser "ruido
aceptable" y demasiado grandes para simplemente borrarse sin perder la mayoría del
dataset.

**Política general de Silver adoptada:**
1. **No se elimina ni se "corrige" (inventa) ningún valor** para resolver una
   inconsistencia cronológica o de negocio detectada — no hay forma de saber, sin
   acceso al sistema origen, cuál de las dos fechas es la errónea. Se **preserva la
   fila completa** y se agrega una columna booleana `_dq_*` que marca la violación,
   para que Gold decida si la incluye, la excluye o la reporta aparte.
2. **Deduplicación solo donde la evidencia confirma redundancia real** de la misma
   entidad/evento (caso `university.grades`, ver §2.2). Donde la evidencia muestra
   entidades distintas que coinciden en un atributo (nombre, fecha de nacimiento),
   **no se deduplica**.
3. **Tipado correcto**: toda columna de fecha en texto se castea a `DATE` o
   `TIMESTAMP` según corresponda (ver detalle de cuál es cuál en el encabezado de
   cada script SQL); montos a `NUMERIC(14,2)`.
4. **Estandarización**: emails a minúsculas y sin espacios; texto con `TRIM`.
5. **Trazabilidad**: cada tabla Silver conserva `_source_domain`, `_source_file`,
   `_ingested_at` (heredadas de Bronze) y agrega `_silver_loaded_at`.

Esta política es la que se implementó en `sql/silver/*.sql` (detalle por tabla en
§4). Ninguna fila de Bronze se pierde al pasar a Silver — el conteo de filas debe
coincidir 1:1 entre `bronze.<tabla>` y `silver.<tabla>` excepto en
`university_grades`, donde se espera una reducción de 60.000 a
60.000 − 12.323 = 47.677 filas por la deduplicación decidida en §2.2 (verificado
ejecutando `src/transform/build_silver.py`: la tabla resultante tiene exactamente
47.677 filas).

---

## 4. Reglas de calidad aplicadas en Silver (detalle por tabla)

Implementadas en `sql/silver/silver_university.sql`, `sql/silver/silver_billing.sql`
y `sql/silver/silver_crm.sql`, ejecutadas por `src/transform/build_silver.py`.

| Tabla Silver | Tipado aplicado | Deduplicación | Columnas `_dq_*` agregadas |
|---|---|---|---|
| `silver.university_semesters` | `start_date`/`end_date` → `DATE` | no aplica | — |
| `silver.university_professors` | `hired_at` → `DATE`; email normalizado | no (ver §2.2) | — |
| `silver.university_courses` | tipos sin cambio | no aplica | `_dq_professor_dept_mismatch` |
| `silver.university_students` | `birth_date`, `enrolled_at` → `DATE`; email normalizado | no (ver §2.2) | `_dq_enrolled_after_first_course` |
| `silver.university_enrollments` | `enrolled_at` → `DATE` | no (son retomas legítimas, §2.2) | `_dq_outside_semester_range`; se agrega `attempt_number` (1=primer intento, 2=retoma, …) |
| `silver.university_grades` | `graded_at` → `DATE` | **sí** — se conserva 1 fila por (`enrollment_id`,`assessment`), la de `graded_at` más reciente | `_dq_graded_before_enrollment`, `_dq_graded_after_semester_end` |
| `silver.billing_customers` | `created_at` → `TIMESTAMP` (tiene hora, ver §2.3); email normalizado | no | `_dq_country_mismatch_university` |
| `silver.billing_products` | `monthly_price` → `NUMERIC(14,2)` | no aplica | — |
| `silver.billing_subscriptions` | `start_date`/`end_date` → `DATE` | no aplica | `_dq_start_after_end` |
| `silver.billing_invoices` | `issued_at`/`due_at` → `DATE`; `total` → `NUMERIC(14,2)` | no aplica | `_dq_total_mismatch_items` |
| `silver.billing_invoice_items` | `unit_price`/`line_total` → `NUMERIC(14,2)` | no (ver §2.2) | — |
| `silver.billing_payments` | `paid_at` → `DATE`; `amount` → `NUMERIC(14,2)` | no aplica | — |
| `silver.crm_accounts` | `created_at` → `TIMESTAMP`; `annual_revenue` → `NUMERIC(14,2)` | no (ver §2.2) | se agrega `name_occurrence_count` (informativo, no booleano) |
| `silver.crm_contacts` | `created_at` → `TIMESTAMP`; email normalizado | no | `_dq_created_before_account` |
| `silver.crm_leads` | `created_at` → `TIMESTAMP`; email normalizado | no aplica | — |
| `silver.crm_opportunities` | `close_date` → `DATE` **y se renombra a `close_date_estimada`** (ver §2.6); `created_at` → `TIMESTAMP`; `amount` → `NUMERIC(14,2)` | no aplica | `_dq_close_before_created` (ver reinterpretación §2.6) |
| `silver.crm_opportunity_contacts` | `role` con `TRIM` | no aplica | — |
| `silver.crm_activities` | `occurred_at` → `TIMESTAMP` | no aplica | `_dq_occurred_before_contact`, `_dq_occurred_before_opportunity` |

**Nota sobre columnas `_dq_*` sensibles al tiempo de ejecución:** se descartó
persistir un flag para "suscripción activa con `end_date` vencido" (§2.5) porque
`CURRENT_DATE` cambia cada día y el flag quedaría obsoleto apenas se guarda; ese
tipo de verificación relativa a "hoy" se deja como consulta de validación (no como
columna materializada), para correrse en el momento en que se necesite.

---

## 5. Modelado Gold

Implementado en `sql/gold/gold_00_dim_fecha.sql`, `gold_university.sql`,
`gold_billing.sql`, `gold_crm.sql`, ejecutados por `src/transform/build_gold.py`
(mismo patrón que Silver: `DROP TABLE` + `CREATE TABLE AS SELECT`, esquema
`gold` completo y reconstruible desde `silver.*` en cada corrida).

### 5.1 Por qué varias estrellas y no una sola

Es una **constelación de hechos** (varias estrellas independientes, una por
proceso de negocio, unidas solo por la dimensión compartida `dim_fecha`), no una
megaestrella. University y CRM tienen **dos hechos a grano distinto** (patrón
encabezado-detalle); Billing tiene **tres hechos independientes** (no es un
encabezado con dos detalles — ver corrección más abajo). Forzar todo en una
sola tabla de hechos mezclaría granularidades distintas (el error clásico que
hay que evitar en modelado dimensional):

| Dominio | Hecho "encabezado" (grano) | Hecho "detalle" (grano más fino) | Por qué separados |
|---|---|---|---|
| University | `fact_inscripciones` (1 fila = 1 `enrollment_id`) | `fact_notas` (1 fila = 1 `grade_id`) | una inscripción tiene varias notas (quiz/homework/midterm/final/project) |
| CRM | `fact_oportunidades` (1 fila = 1 `opportunity_id`) | `fact_actividades` (1 fila = 1 `activity_id`) | "cuánto vendo" (pipeline) y "cuánto contacto genero" (engagement) son preguntas distintas |

El hecho "detalle" no repite las dimensiones del "encabezado": las hereda
navegando por la clave de negocio hacia el hecho encabezado (`fact_notas.
enrollment_id` → `fact_inscripciones`; `fact_actividades.opportunity_id` →
`fact_oportunidades`), igual que una factura y sus líneas.

**Corrección: Billing no es un par encabezado-detalle, son tres hechos
independientes.**

| Hecho | Grano | Proceso de negocio |
|---|---|---|
| `fact_suscripciones` | 1 fila = 1 `subscription_id` | contrato/suscripción del cliente a un producto |
| `fact_facturas` | 1 fila = 1 `invoice_id` | cuánto se facturó |
| `fact_pagos` | 1 fila = 1 `payment_id` | cuánto se cobró (referencia a `fact_facturas.invoice_id`, patrón encabezado-detalle **entre estas dos**) |

`fact_suscripciones` **no** es detalle ni encabezado de `fact_facturas`:
verificado que `bronze.billing_invoices` no tiene columna `subscription_id`
(ni ninguna otra tabla Bronze la vincula), por lo tanto no existe FK
reconstruible entre una suscripción y las facturas que generó — son tres
preguntas de negocio distintas ("qué contraté", "cuánto se facturó", "cuánto
se cobró") sin jerarquía entre sí, cada una con su propio hecho.

`leads` no tiene hecho ni dimensión propia — es `gold.mart_leads`, tabla
analítica aislada conectada solo a `dim_fecha` (confirmado en §1.3: 0% de match
hacia `contacts`, no hay FK real que modelar).

### 5.2 `dim_fecha` — dimensión conformada

Generada con `generate_series` sobre el rango 2015-01-01 a 2035-12-31 (cubre con
margen las fechas observadas en `silver.*`, la más antigua 2018-01-01). Clave
= `fecha_key` en formato `YYYYMMDD` (entero, ordenable, estándar Kimball); no
necesita SCD porque una fecha nunca cambia de atributos.

Cada hecho tiene tantas columnas `*_fecha_key` como fechas de negocio relevantes
tenga (rol distinto de la misma dimensión): `fact_facturas` tiene
`fecha_emision_key` **y** `fecha_vencimiento_key`; `fact_suscripciones` tiene
`fecha_inicio_key` **y** `fecha_fin_key`; `fact_oportunidades` tiene
`fecha_creacion_key` **y** `fecha_cierre_estimada_key`.

### 5.3 Claves surrogate — SCD Tipo 1 (decisión explícita)

Cada dimensión tiene `<entidad>_key` generado con
`ROW_NUMBER() OVER (ORDER BY <clave_de_negocio>)` — determinístico (mismos datos
de entrada → misma clave siempre) y sin historial: al reconstruir Gold, un
cambio de atributo se sobrescribe, no genera una fila nueva. Se decidió así
(sobre SCD Tipo 2 con `valid_from`/`valid_to`) porque el dataset es una carga
estática/sintética, no un flujo real de actualizaciones en el tiempo — no hay
una segunda carga que dispare cambios reales para justificar el costo de
diseño y validación de un historial completo. Si en el futuro el pipeline pasa
a cargas incrementales reales, este es el punto a revisar.

Consecuencia de esta decisión: Gold, igual que Silver, es **completamente
reconstruible** desde la capa anterior en cada corrida (no hay `MERGE`/`UPSERT`
ni estado que preservar entre ejecuciones) — la única capa verdaderamente
"durable" en el sentido de irremplazable es Bronze.

### 5.4 Qué es dimensión, qué es medida, qué es dimensión degenerada

- **Medida** (mide algo, número agregable): `fact_notas.score`/`weight`,
  `fact_facturas.total`, `fact_pagos.amount`, `fact_oportunidades.amount`.
  Ninguna es trivialmente aditiva a través de todas las dimensiones: `score`
  y `weight` son porcentajes (se promedian, no se suman — ver query de ejemplo
  más abajo); `amount` de oportunidades solo es sumable si se filtra por
  `stage` (sumar oportunidades `lost` junto con `won` no significa nada de
  negocio).
- **Dimensión degenerada** (atributo descriptivo que vive en el hecho porque no
  amerita tabla propia): `fact_inscripciones.status`, `fact_inscripciones.
  attempt_number`, `fact_facturas.status`/`moneda`, `fact_pagos.metodo`,
  `fact_oportunidades.etapa`, `fact_actividades.tipo`/`asunto`.
- **Dimensión propiamente dicha**: todo lo que vive en `dim_*` — describe
  quién/qué/dónde, nunca se agrega.
- Columnas `_dq_*` heredadas de Silver se ubicaron en la dimensión o el hecho
  según a qué grano pertenece el hallazgo original (ej.
  `_dq_professor_dept_mismatch` → `dim_curso`, porque es un atributo del curso;
  `_dq_outside_semester_range` → `fact_inscripciones`, porque es un atributo de
  la inscripción).

Verificado con datos reales tras `build_gold.py`: agrupar `fact_notas` por
`dim_tipo_evaluacion` y promediar `score` da 74,80–75,14 según el tipo — consistente
con lo ya visto en Bronze/Silver, confirmando que el join encabezado-detalle
(`fact_notas` → `fact_inscripciones` → `dim_estudiante`/`dim_curso`) no perdió
ni duplicó filas (47.677 en `fact_notas`, igual que `silver.university_grades`).

### 5.5 `dim_curso` desnormaliza al profesor — no hay `dim_profesor`

Decisión explícita: en vez de "snowflakear" (`dim_curso` → `dim_profesor` en
tabla aparte), el nombre/apellido/departamento del profesor se trae directo a
`dim_curso` como columnas denormalizadas. Sigue siendo posible agrupar "carga
docente por profesor" agrupando `dim_curso` por `professor_id`/`profesor_nombre`
sin necesitar una tabla adicional — es la técnica estándar de modelado
dimensional (evitar joins de más en Gold a costa de un poco de redundancia
controlada, aceptable porque `professor_id`↔nombre no cambia por fila).

### 5.6 Fuera de alcance de esta primera versión (decisión de scope, no olvido)

- `fact_invoice_items` (detalle a nivel de línea de factura): no se modeló esta
  vez. Se agrega si una métrica de negocio concreta lo requiere (ej. "ingresos
  por categoría de producto").
- `crm_opportunity_contacts` (tabla puente N:N): no se modeló como *factless
  fact table* esta vez; se retoma si se necesita analizar roles de contacto
  por oportunidad.
- Todas las conteos de filas Silver→Gold coinciden 1:1 en las 17 tablas
  (`dim_fecha` es la única sin equivalente Silver, generada independientemente)
  — verificado ejecutando `src/transform/build_gold.py`.

### 5.7 Puente entre las constelaciones university y billing

`dim_fecha` conecta las tres estrellas por tiempo, pero **no** representa la
relación real entre negocios que sí existe: `billing.customers.external_ref`
↔ `university.students.student_id` (verificada en Bronze, §1.1 — 5.000 de
5.000 `external_ref` no nulos matchean un `student_id` real, 0 huérfanos,
relación 1:1). Hasta esta revisión esa relación solo estaba documentada en
Bronze y no se reflejaba como relación declarada en el modelo Gold.

Se agrega ahora `ALTER TABLE gold.dim_cliente ADD FOREIGN KEY (external_ref)
REFERENCES gold.dim_estudiante (student_id)` en `sql/gold/gold_billing.sql`
(se ejecuta después de `gold_university.sql`, que ya crea `dim_estudiante`).
Es **nullable** a propósito: solo 5.000 de 10.000 clientes tienen estudiante
asociado, y no tiene sentido de negocio forzar que todo cliente sea
estudiante. Con esto, "clientes que también son estudiantes" (o
"facturación por estudiante") deja de ser un join implícito que solo
funciona si se conoce Bronze, y pasa a ser una relación explícita y
consultable en Gold.

No se creó una dimensión puente ni un hecho nuevo para esto — la FK directa
alcanza porque la relación es 1:1 (no N:N) y ya está en una columna existente
de `dim_cliente`; agregar una tabla intermedia sería complejidad sin
beneficio.

---

## 6. Transformaciones de negocio (Gold KPIs)

Implementado en `sql/gold/gold_kpis.sql`, ejecutado por `build_gold.py` después
de `gold_university.sql`, `gold_billing.sql` y `gold_crm.sql` (los KPI leen de
los `dim_*`/`fact_*` ya construidos, incluyendo el cruce cross-domain de §5.7).
Mismo patrón de siempre: `DROP TABLE` + `CREATE TABLE AS SELECT`, reconstruible
en cada corrida.

### 6.1 University

- `kpi_tasa_aprobacion_curso` / `kpi_tasa_aprobacion_semestre`: mismo cálculo
  (aprobadas / finalizadas), a dos granos distintos (curso y semestre) porque
  responden preguntas distintas ("¿qué curso reprueba más?" vs. "¿mejora la
  aprobación semestre a semestre?"). El denominador es `completed + failed`,
  no el total de inscripciones — `active` y `dropped` no son un resultado
  académico todavía, incluirlos en el denominador subestimaría la tasa real.
- `kpi_promedio_notas_tipo_evaluacion`: promedio de `score`/`weight` por tipo
  de evaluación (grano = catálogo de 5 valores).
- `kpi_estudiantes_en_riesgo`: solo estudiantes con al menos 1 curso reprobado
  (`HAVING`), no los 5.000 — es una lista de atención, no un catálogo completo.

### 6.2 Billing

- `kpi_facturacion_mensual`: grano (`anio`,`mes`), total facturado vs. total
  cobrado por mes. Se calculan por separado (`fact_facturas.fecha_emision_key`
  vs. `fact_pagos.fecha_pago_key`) porque, como ya se documentó en §2.5, no
  reconcilian — este KPI expone esa brecha mes a mes en vez de esconderla.
- `kpi_mrr_producto`: MRR **aproximado** = suscripciones en estado `active` ×
  `precio_mensual`, por producto. Deliberadamente no se construyó un MRR
  mes-a-mes con spine de calendario: `start_date`/`end_date` de
  `billing_subscriptions` ya se documentó en §2.5 como poco confiable (47,7%
  de las suscripciones `active` tienen `end_date` vencido), así que un cálculo
  mes-a-mes basado en esas fechas heredaría el mismo ruido sin agregar
  precisión real — se prefiere un número simple y explícitamente etiquetado
  como aproximado sobre uno mensual falsamente preciso.
- `kpi_suscripciones_vencidas`: lista de suscripciones `active` con
  `end_date` ya pasado respecto a `CURRENT_DATE`. A diferencia de la decisión
  en Silver (§4, nota final) de **no** persistir esto como columna `_dq_*`
  porque quedaría obsoleta, aquí sí se materializa como tabla — Gold ya es
  completamente reconstruible en cada corrida (§5.3), así que esta tabla
  siempre refleja "vencidas a la fecha de la última corrida", que es
  exactamente la pregunta de negocio que responde.

### 6.3 CRM

- `kpi_pipeline_oportunidades`: conteo/monto por `etapa` (grano = etapa, 6
  filas).
- `kpi_tasa_cierre_oportunidades`: tabla de una sola fila (`ganadas`/
  `perdidas`/tasa) — patrón válido para un KPI escalar de resumen, pensado
  para consumirse como tarjeta de número único en el dashboard (Metabase),
  no como tabla para cruzar con otras dimensiones.
- `kpi_engagement_cuenta`: intentos iniciales sumaban actividades por cuenta
  contando tanto la cuenta del contacto como la de la oportunidad de cada
  actividad (`UNION` de ambos caminos). Al validarlo apareció un hallazgo no
  documentado antes: **de las 7.020 actividades con contacto y oportunidad a
  la vez, 7.019 (99,99%) tienen la cuenta del contacto distinta a la cuenta
  de la oportunidad** — verificado con
  `dim_contacto.cuenta_key <> fact_oportunidades.cuenta_key`. Es tan
  sistemático que no se lee como "una actividad cruzada entre dos cuentas
  socias" sino como el mismo patrón ya visto en `crm_accounts` (§2.2,
  generador sintético sin coherencia entre columnas relacionadas) — se
  documenta acá como hallazgo de calidad nuevo, no bloquea el KPI pero sí
  cambia su diseño: contar ambos caminos sin filtrar **duplicaba** el
  conteo de actividades por cuenta (la suma total daba 24.038 sobre 17.019
  actividades realmente vinculadas a alguna cuenta). Se corrigió para
  atribuir cada actividad a **una sola** cuenta — la del contacto si existe,
  si no la de la oportunidad (`COALESCE`) — de forma que la suma de
  `num_actividades` en todo `kpi_engagement_cuenta` da exactamente 17.019,
  sin doble conteo.
- `kpi_conversion_leads`: grano = `origen` (`source`), no `(origen, estado)` —
  se eligió el grano más simple porque la pregunta de negocio es "¿qué canal
  convierte mejor?", no una matriz completa canal×estado.

### 6.4 Cruce university ↔ billing

- `kpi_facturacion_estudiantes`: usa la FK agregada en §5.7
  (`dim_cliente.external_ref → dim_estudiante.student_id`) para responder
  "cuánto factura un cliente que también es estudiante, y cómo le va
  académicamente". Grano = `dim_estudiante` con `JOIN` (no `LEFT JOIN`) hacia
  `dim_cliente` — da exactamente 5.000 filas, porque los 5.000 `external_ref`
  no nulos matchean 1:1 contra los 5.000 estudiantes (§1.1): en este dataset,
  **todo estudiante tiene un cliente asociado**, no la mitad como podría
  sugerir el 50% de cobertura visto desde el lado de `customers` (10.000
  clientes, solo 5.000 con `external_ref`).

---

## 7. Automatización con Airflow

Implementado en `dags/medallion_pipeline.py`. Tres tareas, dependencia lineal
explícita: `ingest_bronze >> build_silver >> build_gold`. Cada tarea es un
`BashOperator` que invoca el mismo script que hasta ahora se corría a mano
(`src/ingest/load_raw_bronze.py`, `src/transform/build_silver.py`,
`src/transform/build_gold.py`, este último ya incluye `gold_kpis.sql`) —
el DAG no reimplementa lógica, solo orquesta lo que ya existía.

**Por qué funciona sin cambiar los scripts:** los tres calculan
`PROJECT_ROOT` subiendo dos niveles desde su propio archivo
(`parents[2]`), y `docker-compose.yml` monta `../src`, `../sql` y `../data`
directo bajo `/opt/airflow/` (`../src:/opt/airflow/src`, etc.) — dentro del
contenedor, `PROJECT_ROOT` resuelve a `/opt/airflow`, exactamente donde
están montados. El mismo script corre igual en local (`python3
src/ingest/load_raw_bronze.py` desde la raíz del repo) y dentro de Airflow,
sin variables de entorno ni rutas especiales para el DAG.

**Idempotencia:** no es una propiedad nueva que haya que agregar para
Airflow — ya la tenían los tres scripts desde antes (bronze hace
`drop_table` + `create_table` por archivo; silver y gold hacen `DROP TABLE
IF EXISTS ... CASCADE` + `CREATE TABLE AS SELECT` por tabla). Correr el DAG
dos veces seguidas no duplica filas ni requiere `MERGE`/`UPSERT`.

**`schedule=None` (disparo manual), no un cron:** el dataset es una carga
estática y sintética (mismo argumento que la decisión de SCD Tipo 1 en
§5.3) — no hay una fuente que deposite CSV nuevos todos los días para
justificar una corrida programada. Automatizar aquí significa "un clic
ejecuta las tres fases en orden con dependencias explícitas", no "corre
solo a las 3am". Si en el futuro hay ingesta incremental real, este es el
punto para pasar a `schedule="@daily"` (u otro cron).

### 7.1 `dags/.airflowignore` y corrección de `.gitignore`

Al correr el DAG por primera vez, `Fileloc` en la UI de Airflow apuntaba a
`/opt/airflow/dags/.ipynb_checkpoints/medallion_pipeline-checkpoint.py`, no
al archivo real — Jupyter monta todo el repo (`../:/home/jovyan/work` en
`docker-compose.yml`), así que abrir el `.py` ahí genera un checkpoint
dentro de `dags/`, y Airflow escanea esa carpeta de forma recursiva y lo
toma como un DAG más. Se agrega `dags/.airflowignore` (patrones
`\.ipynb_checkpoints` y `__pycache__`) para que Airflow ignore esas rutas
sin importar dónde aparezcan.

De paso se corrigió `.gitignore`: los patrones anteriores
(`/notebooks/.ipynb_checkpoints`, `/src/ingest/.ipynb_checkpoints`) estaban
anclados a una ruta exacta y no cubrían subcarpetas — por eso
`notebooks/documentacion/.ipynb_checkpoints/documentación-checkpoint.ipynb`
había quedado versionado en el commit `Cambios2` sin que nadie lo notara.
Se reemplazan por `**/.ipynb_checkpoints/` y `**/__pycache__/` (cualquier
profundidad) y se remueve el checkpoint que ya estaba trackeado.

---

## 8. Exportación a Parquet

Implementado en `src/transform/export_parquet.py`, agregado como cuarta
tarea del DAG (`build_gold >> export_parquet` en
`dags/medallion_pipeline.py`).

**Alcance: las tres capas, no solo Gold.** El enunciado pide "capas
exportadas" (plural) y la estructura sugerida ya reserva `data/parquet/`
como carpeta única — se interpretó como exportar `bronze`, `silver` y
`gold` completos, no únicamente el modelo de negocio final. Salida:
`data/parquet/<schema>/<tabla>.parquet`, un archivo por tabla, mismo
nombre que en Postgres.

**Cómo se lee cada tabla:** `pandas.read_sql` sobre el mismo `engine` de
`src/ingest/db.py` que ya usan `load_raw_bronze.py`/`build_silver.py`/
`build_gold.py`, y `DataFrame.to_parquet(engine="pyarrow")`. Se descartó
usar `duckdb` (está en `requirements.txt` desde el commit inicial pero no
se usa en ningún script todavía) para no mezclar dos formas distintas de
leer Postgres en el mismo pipeline — `pandas`/`sqlalchemy` ya es el patrón
establecido en todo `src/`.

**Idempotencia:** cada corrida sobrescribe el `.parquet` de cada tabla
(mismo nombre de archivo) — no acumula versiones ni duplica filas,
consistente con que `bronze`/`silver`/`gold` en Postgres también se
reconstruyen completos en cada corrida (§3, §5).

---

## 9. Validación del pipeline

Implementado en `src/validate/validate_pipeline.py`, agregado como quinta y
última tarea del DAG (`export_parquet >> validate_pipeline`). A diferencia
de los pasos anteriores, esta tarea no transforma nada — solo lee conteos
en cuatro puntos de la cadena y compara. Si algo no cuadra, termina con
`sys.exit(1)`: Airflow marca la tarea (y la corrida) en rojo, que es lo que
pide el criterio "Automatización... con manejo de errores" — un
desajuste de conteos no debe pasar silencioso.

**Cuatro reconciliaciones, en orden de la cadena real:**

1. **CSV → Bronze**: cuenta filas de cada CSV en `data/raw/` con `pandas`
   y las compara contra `bronze.<dominio>_<archivo>`. Deben coincidir
   exacto — Bronze no transforma ni filtra nada (§5 de este documento, "Por
   qué el Bronze exhaustivo importaba").
2. **Bronze → Silver**: mismo criterio (conteo igual) para las 18 tablas,
   con una sola excepción explícita: `university_grades`. Ahí el chequeo
   no compara contra el conteo de Bronze, sino contra
   `COUNT(DISTINCT (enrollment_id, assessment))` calculado sobre Bronze en
   el momento — es la misma regla de deduplicación de §2.2/§4, expresada
   como consulta en vez de como número fijo (`12.323`), para que la
   validación siga siendo correcta aunque cambien los datos de origen.
3. **Silver → Gold**: mapeo explícito de las 15 tablas Silver con
   equivalente 1:1 en Gold (`SILVER_TO_GOLD` en el script). Las 3 que no
   tienen equivalente (`university_professors`, `billing_invoice_items`,
   `crm_opportunity_contacts`) se listan como **verificadas y fuera de
   alcance por diseño** (§5.6), no se omiten en silencio — el reporte deja
   explícito que la ausencia fue una decisión, no un olvido. `dim_fecha`
   (generada, sin origen en Silver) y las 12 tablas `kpi_*` (agregadas, no
   1:1 por definición) no entran en esta reconciliación por la misma
   razón.
4. **Postgres (gold) → Parquet**: para cada tabla de `bronze`/`silver`/`gold`,
   compara el conteo en Postgres contra `len(pd.read_parquet(...))` del
   archivo exportado en §8 — confirma que la exportación no truncó ni
   duplicó filas.

**Qué no revalida (y por qué):** las llaves huérfanas dentro de `gold` no
se comprueban aquí porque ya están garantizadas estructuralmente por las
`FOREIGN KEY` agregadas en cada `gold_*.sql` (§5) — Postgres no deja
insertar una fila huérfana, así que un chequeo aparte sería redundante. Lo
que sí valida este script es lo que **no** está protegido por una
constraint: conteos entre capas y entre Postgres y los archivos exportados.

**Probado con una falla real inyectada:** se borró una fila de
`bronze.billing_products`, se corrió `validate_pipeline.py`, y detectó
correctamente las 3 reconciliaciones afectadas
(`csv->bronze`, `bronze->silver`, `parquet bronze.billing_products`) con
`exit(1)`; se reconstruyó el pipeline completo después para restaurar el
estado. Confirma que el script realmente compara, no solo imprime "OK".

## 10. `docker/.env.example`

`docker-compose.yml` lee credenciales desde variables de entorno
(`WAREHOUSE_DB_USER`, `AIRFLOW_DB_PASSWORD`, `JUPYTER_TOKEN`, etc.) a
través de un archivo `docker/.env` que está en `.gitignore` — correcto no
versionar credenciales, pero eso dejaba a cualquiera que clonara el repo
sin saber qué variables definir, y `docker compose up` fallaría o
arrancaría con valores vacíos. Se agrega `docker/.env.example` (sí
versionado) con valores de ejemplo para las 7 variables que
`docker-compose.yml` espera, para que "levantar el ambiente desde cero"
sea `cp docker/.env.example docker/.env` + `docker compose up`, sin tener
que adivinar nombres de variables leyendo el YAML.

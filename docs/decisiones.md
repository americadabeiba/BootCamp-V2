# Discovery

## Hallazgo: vínculo university-billing
- billing.customers.external_ref coincide en formato y valor con bronze.university_students.student_id
- students=5000, customers=10000 → máx. 50% de customers tienen estudiante asociado
- Verificado: [N] de 5000 estudiantes encontrados en customers.external_ref
- Nombre/país no coinciden entre student y customer vinculados → hipótesis:
  dato generado de forma independiente por tabla (seed=42, generador sintético),
  no necesariamente una persona distinta (tutor). Pendiente de verificar con muestra manual.
  También podria tratarse de un tutor

## Hallazgo: crm sin llave hacia billing/university
- No existe columna compartida entre accounts/opportunities y customers/students
- Hipótesis (no confirmable con llave): customers Enterprise/SMB podrían corresponder
  a accounts de CRM que ganaron una oportunidad. Se evaluará con señales indirectas
  (fechas, montos), documentando que es correlación, no join verificado.

## Decisión: leads se trata como tabla independiente
- No tiene FK hacia accounts/contacts/opportunities por diseño (representa pre-conversión)
- Se modelará como mart de funnel de marketing aislado (tasa de conversión por source/status)

---

# Capa Bronze

## 1. Nulos

Ninguna de las 18 tablas Bronze presenta nulos en las columnas perfiladas
(`COUNT(*) FILTER (WHERE col IS NULL)` = 0 en todos los casos), con dos excepciones
esperadas por diseño del esquema:

- `crm.activities.contact_id`: 5.976 de 20.000 filas (29,9%) nulas.
- `crm.activities.opportunity_id`: 9.985 de 20.000 filas (49,9%) nulas.

Ambas son nulas por diseño (una actividad puede asociarse a un contacto **o** a una
oportunidad, no necesariamente a ambos) — no se tratan como defecto, pero sí como
regla a preservar en Silver (no forzar `NOT NULL`).

## 2. Duplicados

| Tabla | Hallazgo | Magnitud |
|---|---|---|
| `university.professors` | Pares nombre+apellido repetidos (IDs distintos) | 6 pares |
| `university.students` | Ternas nombre+apellido+fecha de nacimiento repetidas | 3 ternas |
| `university.enrollments` | Duplicados por clave de negocio (student+course+semester) | 23 pares |
| `university.grades` | Duplicados por (enrollment_id + assessment) — dos notas del mismo tipo para la misma inscripción | **10.544 filas (17,6% de 60.000)** |
| `billing.customers` | Email duplicado | 0 |
| `billing.products` | SKU duplicado | 0 |
| `billing.invoice_items` | Mismo producto repetido en la misma factura (invoice_id+product_id) | 1.103 pares |
| `crm.accounts` | Nombre de cuenta repetido (posibles cuentas duplicadas, distinto `account_id`) | **599 nombres, hasta 17 repeticiones** (p. ej. "Azteca Data") |
| `crm.contacts` | Email duplicado | 2 |
| `crm.leads` | Email duplicado | 0 |
| `crm.opportunity_contacts` | Par (opportunity_id, contact_id) duplicado | 0 |

**Prioridad alta para Silver:** `university.grades` (17,6% duplicado por
enrollment+assessment) y `crm.accounts` (599 nombres repetidos) — requieren regla de
deduplicación explícita antes de agregar notas o contar cuentas únicas.

## 3. Formatos inconsistentes

- Todas las columnas de fecha en texto (`created_at`, `start_date`, `end_date`,
  `issued_at`, `due_at`, `paid_at`, `occurred_at`, `hired_at`) fueron validadas con
  regex `^\d{4}-\d{2}-\d{2}` contra los 18 CSV: **0 filas con formato no parseable**
  en ningún dominio. El formato de fecha es consistente (ISO `YYYY-MM-DD`).
- `crm.activities.subject`: ratio de unicidad = 1.0 (20.000/20.000 valores distintos)
  — confirma que es texto libre, no una categoría; no perfilar como categórica en
  Silver/Gold.

## 4. Llaves huérfanas (integridad referencial)

Todas las FK explícitas dentro de cada dominio están limpias — **0 huérfanas** en:
`enrollments→students/courses/semesters`, `grades→enrollments`,
`subscriptions→customers/products`, `invoices→customers`,
`invoice_items→invoices/products`, `payments→invoices`,
`contacts→accounts`, `opportunities→accounts`,
`opportunity_contacts→opportunities/contacts`,
`activities→contacts/opportunities` (sobre los valores no nulos).

Huérfanos "débiles" (sin romper FK, pero indicando registros sin actividad):

- **38 estudiantes** (`university.students`) sin ninguna inscripción en
  `enrollments`.

Relaciones cross-dominio sin llave declarada (ver detalle y decisión en
`docs/decisiones.md`):

- `billing.customers.external_ref` ↔ `university.students.student_id`: 5.000/10.000
  customers (50%) tienen `external_ref`, y el 100% de esos matchean un `student_id`
  real — vínculo confirmado, sin huérfanos.
- `crm.contacts.email` ↔ `billing.customers.email`: solo **1 de 15.000** contactos
  matchea un email de `customers` → prácticamente no hay solapamiento explotable por
  email entre CRM y Billing.
- `crm.leads.email` ↔ `crm.contacts.email`: **0 de 2.000** leads matchean un contacto
  existente → la conversión lead→contacto no es reconstruible con los datos
  disponibles (confirma la decisión de tratar `leads` como tabla aislada).

---

## Inconsistencias lógicas

### University
- **264 de 300 cursos (88%)** son dictados por un profesor de un departamento
  distinto al del curso — posible dato esperado del generador sintético, pero a
  revisar si el negocio espera coherencia departamento-profesor/curso.
- **1.851 de 5.000 estudiantes (37%)** tienen `enrolled_at` (fecha de alta) posterior
  a su primera inscripción real en `enrollments` — inconsistencia cronológica.
- **22.729 de 25.000 enrollments (91%)** tienen `enrolled_at` fuera del rango
  `[start_date, end_date]` del semestre asociado — la inmensa mayoría de las
  inscripciones no calzan con su semestre.
- **29.241 de 60.000 grades (48,7%)** tienen `graded_at` anterior a `enrolled_at` de
  su inscripción — calificado antes de inscribirse, imposible cronológicamente.
- **26.828 de 60.000 grades (44,7%)** tienen `graded_at` posterior al `end_date` del
  semestre correspondiente.
- **22.104 enrollments** tienen la suma de `weight` de sus notas fuera del rango
  esperado (ni ~1 ni ~100) — la ponderación de evaluaciones no cuadra en una porción
  importante de los casos.
- Rango de `score` correcto (24,53–100), sin valores fuera de `[0,100]`.

### Billing
- **789 de 15.000 subscriptions (5,3%)** tienen `start_date >= end_date`
  (fechas invertidas).
- **7.154 de 15.000 subscriptions (47,7%)** están en estado `active` con `end_date`
  ya vencido respecto a la fecha de ejecución de la consulta — suscripciones "activas"
  que ya deberían estar cerradas (revisar con el negocio si `status` se actualiza por
  batch o si es un estado real desincronizado).
- **49.999 de 50.000 invoices (~100%)** tienen `total` que **no** coincide con la
  suma de `invoice_items.line_total` asociados — el campo `total` de la factura no
  es reconciliable con sus líneas en prácticamente ningún caso. Es el hallazgo más
  relevante de todo el dataset: cualquier métrica de facturación en Gold que use
  `invoices.total` y otra que use `SUM(invoice_items.line_total)` va a dar cifras
  distintas; hay que decidir y documentar cuál es la fuente de verdad antes de Silver.
- La reconciliación `SUM(payments.amount)` vs `invoices.total` también muestra
  diferencias generalizadas en ambos sentidos (facturas sin pagar y facturas
  sobre-pagadas), consistente con que `total` no está atado a items ni a pagos en
  este dataset sintético.
- `invoice_items`: `line_total = quantity × unit_price` se cumple en el 100% de las
  150.000 filas — la inconsistencia está en `invoices.total`, no en las líneas.

### CRM
- **7.451 de 15.000 contacts (49,7%)** tienen `created_at` anterior al `created_at`
  de su `account_id` — el contacto "existe" antes que la cuenta, imposible
  cronológicamente.
- **1.029 de 3.000 opportunities (34,3%)** tienen `close_date` anterior a
  `created_at` — cerrada antes de abierta.
- **2.579 de ~14.024 activities con `contact_id`** (18,4%) ocurrieron antes de la
  creación del contacto asociado.
- **3.790 de ~10.015 activities con `opportunity_id`** (37,8%) ocurrieron antes de
  la creación de la oportunidad asociada.
- `crm.accounts`: `annual_revenue` (11.003,91–64.944.915,65) y `employees`
  (1–6.521) sin negativos.

---

## 6. Para Silver

| Prioridad | Hallazgo | Acción sugerida |
|---|---|---|
| Alta | `invoices.total` no reconciliable con `invoice_items` (~100% de las facturas) | Decidir fuente de verdad (recalcular `total` desde items, o mantener `total` original y exponer la diferencia como columna) y documentar la decisión |
| Alta | 91% de `enrollments.enrolled_at` fuera del rango del semestre; ~49% de `grades.graded_at` antes del `enrolled_at` | Definir regla de tratamiento (¿se descartan, se marcan, se aceptan como ruido del generador?) antes de construir métricas académicas en Gold |
| Alta | `university.grades` con 17,6% de duplicados por (enrollment+assessment) | Regla de deduplicación (última nota, promedio, o rechazo) antes de calcular promedios |
| Media | Fechas de creación invertidas en `contacts`/`opportunities` (37–50%) | Documentar como limitación del dataset sintético; no bloquea el modelado pero debe excluirse de cualquier análisis de "tiempo hasta conversión" |
| Media | 599 nombres de cuenta duplicados en `crm.accounts` | Definir si se deduplican por nombre o se tratan como cuentas legítimamente distintas (sucursales) |
| Baja | 30/200 productos inactivos, 38 estudiantes sin inscripción, huérfanos débiles | Filtrar o marcar explícitamente en Silver, no requieren limpieza estructural |
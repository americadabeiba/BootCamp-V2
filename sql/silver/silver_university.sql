-- Silver — dominio university
-- Reglas y justificación de cada decisión: docs/decisiones.md (secciones 2, 3 y 4).
-- Política general: no se borra ni se "corrige" ninguna fila por inconsistencia de
-- fecha/negocio; se tipa, se estandariza y se marca con columnas _dq_* cuando aplica.

CREATE SCHEMA IF NOT EXISTS silver;

-- ---------------------------------------------------------------------------
-- semesters: sin hallazgos de calidad (docs/decisiones.md §2.5). Solo tipado.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.university_semesters CASCADE;
CREATE TABLE silver.university_semesters AS
SELECT
    TRIM(semester_id)          AS semester_id,
    TRIM(code)                 AS code,
    year::INTEGER              AS year,
    half::INTEGER              AS half,
    start_date::DATE           AS start_date,
    end_date::DATE             AS end_date,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'   AS _silver_loaded_at
FROM bronze.university_semesters;

ALTER TABLE silver.university_semesters ADD PRIMARY KEY (semester_id);

-- ---------------------------------------------------------------------------
-- professors: 6 pares nombre+apellido repetidos con professor_id distinto — no
-- se deduplica (sin evidencia de que sean la misma persona). Solo tipado.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.university_professors CASCADE;
CREATE TABLE silver.university_professors AS
SELECT
    TRIM(professor_id)              AS professor_id,
    TRIM(first_name)                AS first_name,
    TRIM(last_name)                 AS last_name,
    LOWER(TRIM(email))              AS email,
    TRIM(department)                AS department,
    hired_at::DATE                  AS hired_at,
    _source_domain,
    _source_file,
    _ingested_at,
    now() AT TIME ZONE 'UTC'        AS _silver_loaded_at
FROM bronze.university_professors;

ALTER TABLE silver.university_professors ADD PRIMARY KEY (professor_id);

-- ---------------------------------------------------------------------------
-- courses: 88% de los cursos con profesor de otro departamento
-- (docs/decisiones.md §2.5) — se preserva y se marca, no se corrige.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.university_courses CASCADE;
CREATE TABLE silver.university_courses AS
SELECT
    TRIM(c.course_id)                              AS course_id,
    TRIM(c.code)                                    AS code,
    TRIM(c.name)                                    AS name,
    c.credits::INTEGER                              AS credits,
    TRIM(c.department)                              AS department,
    TRIM(c.professor_id)                            AS professor_id,
    COALESCE(p.department <> c.department, FALSE)   AS _dq_professor_dept_mismatch,
    c._source_domain,
    c._source_file,
    c._ingested_at,
    now() AT TIME ZONE 'UTC'                        AS _silver_loaded_at
FROM bronze.university_courses c
LEFT JOIN bronze.university_professors p
    ON p.professor_id = c.professor_id;

ALTER TABLE silver.university_courses ADD PRIMARY KEY (course_id);

-- ---------------------------------------------------------------------------
-- students: 3 ternas nombre+apellido+nacimiento repetidas con student_id/email
-- distinto — no se deduplica (docs/decisiones.md §2.2). 37% con enrolled_at
-- (alta) posterior a su primera inscripción real — se marca (§2.5).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.university_students CASCADE;
CREATE TABLE silver.university_students AS
SELECT
    TRIM(s.student_id)                                      AS student_id,
    TRIM(s.first_name)                                      AS first_name,
    TRIM(s.last_name)                                       AS last_name,
    LOWER(TRIM(s.email))                                    AS email,
    s.birth_date::DATE                                      AS birth_date,
    s.enrolled_at::DATE                                     AS enrolled_at,
    TRIM(s.country)                                         AS country,
    COALESCE(s.enrolled_at::DATE > m.first_course_at, FALSE) AS _dq_enrolled_after_first_course,
    s._source_domain,
    s._source_file,
    s._ingested_at,
    now() AT TIME ZONE 'UTC'                                AS _silver_loaded_at
FROM bronze.university_students s
LEFT JOIN (
    SELECT student_id, MIN(enrolled_at::DATE) AS first_course_at
    FROM bronze.university_enrollments
    GROUP BY student_id
) m ON m.student_id = s.student_id;

ALTER TABLE silver.university_students ADD PRIMARY KEY (student_id);

-- ---------------------------------------------------------------------------
-- enrollments: 23 pares con la misma clave de negocio (student+course+semester)
-- pero status/enrolled_at distintos — son retomas legítimas, NO se deduplica
-- (docs/decisiones.md §2.2); se agrega attempt_number para distinguirlas en
-- Gold. 91% con enrolled_at fuera del rango del semestre — se marca (§2.5).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.university_enrollments CASCADE;
CREATE TABLE silver.university_enrollments AS
SELECT
    TRIM(e.enrollment_id)                                   AS enrollment_id,
    e.enrolled_at::DATE                                     AS enrolled_at,
    TRIM(e.status)                                           AS status,
    TRIM(e.student_id)                                       AS student_id,
    TRIM(e.course_id)                                        AS course_id,
    TRIM(e.semester_id)                                      AS semester_id,
    ROW_NUMBER() OVER (
        PARTITION BY e.student_id, e.course_id, e.semester_id
        ORDER BY e.enrolled_at::DATE, e.enrollment_id
    )                                                        AS attempt_number,
    COALESCE(
        e.enrolled_at::DATE < sem.start_date::DATE
        OR e.enrolled_at::DATE > sem.end_date::DATE,
        FALSE
    )                                                        AS _dq_outside_semester_range,
    e._source_domain,
    e._source_file,
    e._ingested_at,
    now() AT TIME ZONE 'UTC'                                AS _silver_loaded_at
FROM bronze.university_enrollments e
LEFT JOIN bronze.university_semesters sem
    ON sem.semester_id = e.semester_id;

ALTER TABLE silver.university_enrollments ADD PRIMARY KEY (enrollment_id);

-- ---------------------------------------------------------------------------
-- grades: 17,6% duplicado real por (enrollment_id, assessment) — SE
-- DEDUPLICA, conservando la nota con graded_at más reciente (se asume
-- corrección/recalificación; docs/decisiones.md §2.2). 48,7% calificada antes
-- de la inscripción y 44,7% después del fin de semestre — se marca (§2.5).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.university_grades CASCADE;
CREATE TABLE silver.university_grades AS
WITH ranked AS (
    SELECT
        g.*,
        ROW_NUMBER() OVER (
            PARTITION BY g.enrollment_id, g.assessment
            ORDER BY g.graded_at::DATE DESC, g.grade_id DESC
        ) AS rn
    FROM bronze.university_grades g
)
SELECT
    TRIM(r.grade_id)                                        AS grade_id,
    TRIM(r.assessment)                                       AS assessment,
    r.score::NUMERIC(6, 2)                                   AS score,
    r.weight::NUMERIC(6, 4)                                  AS weight,
    r.graded_at::DATE                                        AS graded_at,
    TRIM(r.enrollment_id)                                    AS enrollment_id,
    COALESCE(r.graded_at::DATE < e.enrolled_at::DATE, FALSE) AS _dq_graded_before_enrollment,
    COALESCE(r.graded_at::DATE > sem.end_date::DATE, FALSE)  AS _dq_graded_after_semester_end,
    r._source_domain,
    r._source_file,
    r._ingested_at,
    now() AT TIME ZONE 'UTC'                                AS _silver_loaded_at
FROM ranked r
LEFT JOIN bronze.university_enrollments e
    ON e.enrollment_id = r.enrollment_id
LEFT JOIN bronze.university_semesters sem
    ON sem.semester_id = e.semester_id
WHERE r.rn = 1;

ALTER TABLE silver.university_grades ADD PRIMARY KEY (grade_id);

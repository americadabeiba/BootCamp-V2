-- Gold — estrella university
-- Justificación del diseño: docs/decisiones.md, sección "5. Modelado Gold".
-- Dos hechos a grano distinto (inscripción vs. nota) en vez de uno solo mezclado;
-- dim_curso desnormaliza al profesor (sin dim_profesor aparte); claves surrogate
-- (SCD tipo 1, sin historial, reconstruible completo en cada corrida).

CREATE SCHEMA IF NOT EXISTS gold;

-- ---------------------------------------------------------------------------
-- dim_tipo_evaluacion: catálogo chico (5 valores) derivado de assessment.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dim_tipo_evaluacion CASCADE;
CREATE TABLE gold.dim_tipo_evaluacion AS
SELECT
    ROW_NUMBER() OVER (ORDER BY assessment) AS tipo_evaluacion_key,
    assessment                               AS tipo_evaluacion
FROM (SELECT DISTINCT assessment FROM silver.university_grades) t;

ALTER TABLE gold.dim_tipo_evaluacion ADD PRIMARY KEY (tipo_evaluacion_key);
CREATE UNIQUE INDEX ON gold.dim_tipo_evaluacion (tipo_evaluacion);

-- ---------------------------------------------------------------------------
-- dim_semestre
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dim_semestre CASCADE;
CREATE TABLE gold.dim_semestre AS
SELECT
    ROW_NUMBER() OVER (ORDER BY semester_id) AS semestre_key,
    semester_id,
    code                                      AS codigo,
    year                                      AS anio,
    half                                      AS periodo,
    start_date                                AS fecha_inicio,
    end_date                                  AS fecha_fin
FROM silver.university_semesters;

ALTER TABLE gold.dim_semestre ADD PRIMARY KEY (semestre_key);
CREATE UNIQUE INDEX ON gold.dim_semestre (semester_id);

-- ---------------------------------------------------------------------------
-- dim_curso: desnormaliza nombre/apellido/departamento del profesor (no hay
-- dim_profesor aparte, por decisión explícita — evita snowflake innecesario).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dim_curso CASCADE;
CREATE TABLE gold.dim_curso AS
SELECT
    ROW_NUMBER() OVER (ORDER BY c.course_id)  AS curso_key,
    c.course_id,
    c.code                                     AS codigo,
    c.name                                     AS nombre,
    c.credits                                  AS creditos,
    c.department                               AS departamento_curso,
    c.professor_id,
    p.first_name                               AS profesor_nombre,
    p.last_name                                AS profesor_apellido,
    p.department                               AS profesor_departamento,
    c._dq_professor_dept_mismatch
FROM silver.university_courses c
LEFT JOIN silver.university_professors p
    ON p.professor_id = c.professor_id;

ALTER TABLE gold.dim_curso ADD PRIMARY KEY (curso_key);
CREATE UNIQUE INDEX ON gold.dim_curso (course_id);

-- ---------------------------------------------------------------------------
-- dim_estudiante
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dim_estudiante CASCADE;
CREATE TABLE gold.dim_estudiante AS
SELECT
    ROW_NUMBER() OVER (ORDER BY student_id)   AS estudiante_key,
    student_id,
    first_name                                 AS nombre,
    last_name                                  AS apellido,
    email,
    birth_date                                 AS fecha_nacimiento,
    enrolled_at                                AS fecha_alta,
    country                                    AS pais,
    _dq_enrolled_after_first_course
FROM silver.university_students;

ALTER TABLE gold.dim_estudiante ADD PRIMARY KEY (estudiante_key);
CREATE UNIQUE INDEX ON gold.dim_estudiante (student_id);

-- ---------------------------------------------------------------------------
-- fact_inscripciones: grano = 1 fila por enrollment_id.
-- status y attempt_number son atributos descriptivos (dimensión degenerada),
-- no medidas.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_inscripciones CASCADE;
CREATE TABLE gold.fact_inscripciones AS
SELECT
    e.enrollment_id,
    est.estudiante_key,
    cur.curso_key,
    sem.semestre_key,
    fec.fecha_key                              AS fecha_inscripcion_key,
    e.status,
    e.attempt_number,
    e._dq_outside_semester_range
FROM silver.university_enrollments e
JOIN gold.dim_estudiante est ON est.student_id = e.student_id
JOIN gold.dim_curso cur ON cur.course_id = e.course_id
JOIN gold.dim_semestre sem ON sem.semester_id = e.semester_id
JOIN gold.dim_fecha fec ON fec.fecha = e.enrolled_at;

ALTER TABLE gold.fact_inscripciones ADD PRIMARY KEY (enrollment_id);
ALTER TABLE gold.fact_inscripciones
    ADD FOREIGN KEY (estudiante_key) REFERENCES gold.dim_estudiante (estudiante_key),
    ADD FOREIGN KEY (curso_key) REFERENCES gold.dim_curso (curso_key),
    ADD FOREIGN KEY (semestre_key) REFERENCES gold.dim_semestre (semestre_key),
    ADD FOREIGN KEY (fecha_inscripcion_key) REFERENCES gold.dim_fecha (fecha_key);
CREATE INDEX ON gold.fact_inscripciones (fecha_inscripcion_key);

-- ---------------------------------------------------------------------------
-- fact_notas: grano = 1 fila por grade_id (más fino que fact_inscripciones).
-- No repite estudiante/curso/semestre: se navega a través de
-- fact_inscripciones vía enrollment_id (patrón encabezado-detalle).
-- score/weight son las medidas; ambas no aditivas (ver docs/decisiones.md).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_notas CASCADE;
CREATE TABLE gold.fact_notas AS
SELECT
    g.grade_id,
    g.enrollment_id,
    te.tipo_evaluacion_key,
    fec.fecha_key                              AS fecha_calificacion_key,
    g.score,
    g.weight,
    g._dq_graded_before_enrollment,
    g._dq_graded_after_semester_end
FROM silver.university_grades g
JOIN gold.dim_tipo_evaluacion te ON te.tipo_evaluacion = g.assessment
JOIN gold.dim_fecha fec ON fec.fecha = g.graded_at;

ALTER TABLE gold.fact_notas ADD PRIMARY KEY (grade_id);
ALTER TABLE gold.fact_notas
    ADD FOREIGN KEY (enrollment_id) REFERENCES gold.fact_inscripciones (enrollment_id),
    ADD FOREIGN KEY (tipo_evaluacion_key) REFERENCES gold.dim_tipo_evaluacion (tipo_evaluacion_key),
    ADD FOREIGN KEY (fecha_calificacion_key) REFERENCES gold.dim_fecha (fecha_key);
CREATE INDEX ON gold.fact_notas (enrollment_id);
CREATE INDEX ON gold.fact_notas (fecha_calificacion_key);

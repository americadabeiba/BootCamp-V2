La tabla Leads no tiene conexión con nadie, pordrían ser potebnciales estudiantes/clientes
No hay llaves huérfanas
external_ref en la tabla customer se refiere a student



## Hallazgo: vínculo university-billing
- billing.customers.external_ref coincide en formato y valor con university.students.student_id
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
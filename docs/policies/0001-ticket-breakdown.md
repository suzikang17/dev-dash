---
lore_type: policy
title: Break tickets into tasks
applies_to: ticket
trigger: on_demand, on_work
status: active
---
Break a ticket into child tasks when it implies more than one distinct
deliverable, can't be finished in a single focused sitting, or spans multiple
files or stages. Don't break down a ticket that is already a single concrete
unit of work.

Produce 3–6 tasks. Each must be specific to *this* ticket — not generic
best-practice boilerplate. Don't duplicate tasks the ticket already has.

Output each task on its own line as exactly: `TASK: <title>`

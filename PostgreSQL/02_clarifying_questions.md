# CLARIFYING QUESTIONS — ready to paste to Leonardo (the "customer")

You're a consultant; Leonardo is the customer. Asking sharp, well-timed
questions is graded ("decision making," "attention to detail," "reporting").
Don't spam — ask when it genuinely changes your approach. Aim for a few
high-value questions, not a stream.

Tone: professional, concise, consultative. You confirm scope, you don't
fish for the answer.

---

## AT THE START (scope + rules of engagement)

- "Hi Leonardo — thanks. Before I dive in: is there a specific symptom the
  application team is reporting, or should I treat this as a general health
  check and address what I find?"

- "Is there an approved maintenance window, or should I assume zero planned
  downtime and flag anything that would need an outage for your approval?"

- "Do I have sudo/root on these hosts, and is it acceptable to install
  packages from the standard repositories if a diagnostic tool is missing?"

- "Is there a priority order across the tasks, or should I use my own
  judgement on sequencing?"

- "Are there other nodes involved (replicas, a standby, a pooler), or is this
  a single primary?"

---

## BEFORE ANY DISRUPTIVE ACTION (announce, don't ask permission to think)

- "I've found [X]. Fixing it cleanly needs a PostgreSQL restart (~a few
  seconds of downtime). Given this is production, do you want me to proceed
  now, or hold it for a window? I'll document either way."

- "This table needs a rewrite to reclaim bloat. I'll use pg_repack to avoid an
  exclusive lock so the app stays up — just confirming that's acceptable."

- "I'm going to terminate a backend that's been idle-in-transaction for N
  minutes and holding locks. Confirming you're OK with that connection being
  dropped."

---

## WHEN A TASK IS AMBIGUOUS (surface the assumption)

- "The task says 'optimize this query.' Is the goal lowest latency for this one
  statement, or overall throughput? It changes whether I add an index vs. tune
  work_mem / rewrite the query."

- "For the config tuning — should I optimize purely for this workload's current
  profile, or leave headroom for growth? I'll state my assumption in the report
  regardless."

- "Do you want me to actually apply changes, or produce the recommendation with
  the exact steps for your team to apply? I'll do [X] unless you'd prefer
  otherwise."

---

## WHEN YOU HIT A REAL PROBLEM (show composure — this is explicitly graded)

- "Heads up: I've run into [unexpected thing, e.g. the standby won't come up
  because of a missing WAL segment]. I'm investigating; my working hypothesis
  is [Y]. I'll update you shortly." *(Then actually update.)*

- "I'm blocked on [X] and it's costing time. My plan is to [workaround] and note
  the caveat in the report rather than lose the remaining tasks — flagging so
  you know my reasoning."

---

## STATUS UPDATES (unprompted — signals consulting maturity)
Send 2–4 brief ones across the 3 hours. Not narration of every command —
milestones.

- "Quick update: environment captured, PG is up. Task 1 (disk) root cause found
  — WAL archiving was failing, pg_wal had grown to fill /. Fixing now."

- "Task 1 resolved and verified. Moving to the replication task."

- "~40 min left — closing out the query work and writing the report now."

---

## AT THE END

- "I've completed [N of M] tasks and I'm sending the written report now. I left
  the server running and stable; all modified config files are backed up as
  *.bak. Happy to walk through any decision if useful."

---
### DON'T ask
- The literal answer ("what's wrong with the server?") — you're hired to find it.
- Things you can determine yourself in 30 seconds (versions, RAM, config values).
- Permission for every trivial, reversible, online change — just do it and log it.

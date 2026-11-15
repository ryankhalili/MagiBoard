# MagiBoard development checkpoints

## Shipped — v0.2

Native iPad app and independent Mac companion published. The release passed 29 native tests and 43 Python tests. User confirmed dictation and spoken canvas actions work on the physical iPad.

## In progress — interaction and object refinement

### Completed backend checkpoint

- Four independent requests can run through the companion, each with its own captured reference.
- Databricks managed-volume catalog supports explicit, versioned object save/list/load without starting a SQL warehouse.
- Agent output validates exposed controls and supports conventional equation objects and the canvas-wide widget API.
- All 59 Python tests passed. Live checks passed for concurrent generation, bare fraction transcription, authentication enforcement, and a synthetic catalog round trip.

### Native app verification

The updated app is installed on the connected iPad. Native unit checks passed; the expanded interaction suite is still being verified before the native release checkpoint.

- Unify Magic Pen selection and prompt state; clear abandoned draft focus, preserve each submitted task's reference.
- Run independent AI tasks and merge nonconflicting object changes without interrupting drawing.
- Stabilize tool changes, selection actions, camera movement, and keyboard editing.
- Add a conventional live LaTeX editor and original math layout engine.
- Let interactive objects create and change objects on the parent canvas through a structured host API.
- Expose labeled parameter controls; make reusable object packages importable and shareable.
- Repair photo/file insertion and center the ribbon tabs.
- Connect an explicitly saved cloud object catalog to Databricks, with local editing preserved.
- Refresh the original app icon; validate, install, and push completed changes.

Only checked, completed milestones are described as shipped. Credentials, notebook data, pairing files, and local runtime configuration remain outside version control.

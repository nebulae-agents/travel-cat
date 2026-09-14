# Travel Cat Journal Runtime Contract

- Authoritative entry: `../../../scripts/run-travelcatctl`, resolved from this reference's installed plugin root.
- Journal read root: the same journal response's `runtime.dataRoot`; missing metadata fails closed.
- Automation identity: exactly one Travel Cat heartbeat attached to the relevant task, matched by stable context and prompt rather than a pet title.
- Use these five intents only: 当前旅程, 最新明信片, 旅行册, 暂停旅行, 继续旅行.
- Interactive reads must use `run-travelcatctl journal` only and must never call `claim`, `publish`, `pending-images`, or `mark-image`.
- If the user asks for `暂停旅行`, pause exactly one matching existing automation; none or several is an ambiguity to explain, not permission to create one.
- If the user asks for `继续旅行`, resume exactly one matching existing automation while preserving its other fields.
- Never print event IDs, state versions, hashes, tokens, or filesystem paths.

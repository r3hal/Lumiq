# Focal 2.3.2 / build 22

Codemagic identified `Cannot find location in scope` in EvaluationStore.swift:111. `location` is a local snapshot inside evaluate() and export(), but importDataset() referenced it after awaiting JSON validation. The imported image writes now use the store's directory property on the main actor, matching addImage(), delete() and persist().

Reviewed all location references in the evaluation code: the remaining two snapshots are declared in their respective methods before use. Import validation, image hashes, path checks, busy-state guard, report persistence and the prior duplicate-type fix remain intact. No camera or guidance behavior changes.

Project/data/build-script structural checks pass. Xcode is unavailable here; native compilation and the 314 registered tests still require Codemagic. Start a new ios-sideload build from main at this fix commit, rather than restarting a build pinned to the previous source commit.

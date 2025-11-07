Critical Issues

  1. File naming inconsistency in spec

  - Spec line 29: .limousine-proj
  - Spec line 20: "<path/to/.limousine.proj>" (with dot before "proj")
  - Decision needed: Should it be .limousine-proj or .limousine.proj?

  2. Invalid JSON syntax in spec

  - Spec line 42: "<name>" => { ... } uses => which is not valid JSON
  - Should be "<name>": { ... } with colon
  - Plan assumes correct JSON but doesn't document this

  3. Missing working directory for commands

  - Module service commands need to run in the clone-path directory
  - Docker service commands likely run from project root
  - Plan gap: process/manager.py doesn't mention setting cwd parameter

  4. Relative path resolution not specified

  - Spec allows "relative-or-absolute-path" for clone-path (line 40)
  - Plan gap: Doesn't specify how relative paths resolve (relative to project file location?)

  5. Module config structure underspecified

  - Spec lines 51-56 show module config with env file settings
  - Plan gap: Module class mentions "config" but doesn't detail the structure (active-env-file, source-env-file, etc.)

  Minor Issues

  6. ProcessState output field ambiguous

  - Spec says "output": <open pipe for stdout + stderr>
  - Plan gap: Doesn't explain how this pipe connects to log viewer streaming
  - Need buffer management strategy for large outputs

  7. psutil dependency conflicts with minimalism

  - Plan suggests "Consider: psutil" for process checks
  - Spec emphasizes "minimal dependencies, ideally just tcl/tk, subprocess, and other built-ins"
  - Better approach: Use /proc on Linux, ps command on macOS (both stdlib)

  8. Service tab creation timing unclear

  - Spec says "each service / docker service gets its own service tab" (line 152)
  - Plan clarification needed: Are all tabs created on startup, or created on-demand when clicked?
  - Plan Stage 3.2 mentions "create_tab_on_demand()" suggesting lazy creation (good choice)

  9. Env file update for secrets

  - Spec line 190: "update the active file from the source env file (but not the secrets)"
  - This means: sync regular env keys, but warn about secret mismatches without auto-syncing
  - Plan gap: env_updater.py should clarify separate handling for secrets vs regular env

  10. Settings dialog functionality mismatch

  - Plan includes "configure_logging_level()" in settings
  - Spec only mentions: about dialog with logs and version
  - Question: Is settings dialog scope creep, or reasonable addition?

  Recommendations

  1. Clarify file naming: Use .limousine-proj consistently
  2. Add to Stage 1.4: Working directory support in process manager
  3. Add to Stage 1.2: Explicit ModuleConfig dataclass with env file fields
  4. Add to Stage 1.5: Path resolution utility for relative paths
  5. Revise Stage 3.8: Remove psutil, use platform-specific stdlib approaches
  6. Clarify Stage 3.4: Document that secrets are warned but not auto-synced
  7. Add to Stage 3.1: Buffer management for service tab output streams


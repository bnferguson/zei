# Task List: zei MVP Implementation

## Relevant Files

### Core Modules
- `src/main.zig` - Main entry point and event loop coordination
- `src/config.zig` - YAML configuration parsing and validation
- `src/service.zig` - Service data structures and types
- `src/service_manager.zig` - Service registry and state management
- `src/process.zig` - Process spawning and management
- `src/privilege.zig` - Privilege escalation and user/group handling
- `src/monitor.zig` - Service monitoring and restart logic
- `src/reaper.zig` - Process reaping and zombie prevention
- `src/logger.zig` - Logging infrastructure and output capture
- `src/shutdown.zig` - Graceful shutdown handling
- `src/signals.zig` - Signal handling infrastructure

### Test Files
- `src/config.test.zig` - Tests for configuration parsing
- `src/service_manager.test.zig` - Tests for service management
- `src/process.test.zig` - Tests for process operations
- `src/privilege.test.zig` - Tests for privilege management
- `src/monitor.test.zig` - Tests for monitoring logic
- `src/reaper.test.zig` - Tests for reaping logic
- `src/logger.test.zig` - Tests for logging
- `src/shutdown.test.zig` - Tests for shutdown
- `tests/integration.zig` - Integration tests with example configs

### Configuration
- `example/zei.yaml` - Example configuration (already exists)
- `tests/fixtures/*.yaml` - Test configuration files

### Notes

- Unit tests should be placed alongside the code files they are testing
- Use `zig build test` to run all tests
- Use `zig test src/[file].zig` to run tests for a specific file
- Integration tests go in the `tests/` directory

## Instructions for Completing Tasks

**IMPORTANT:** As you complete each task, you must check it off in this markdown file by changing `- [ ]` to `- [x]`. This helps track progress and ensures you don't skip any steps.

Example:
- `- [ ] 1.1 Read file` → `- [x] 1.1 Read file` (after completing)

Update the file after completing each sub-task, not just after completing an entire parent task.

## Tasks

- [x] 0.0 Create feature branch
  - [x] 0.1 Branch `claude/pei-zig-port-011CUrkXKjcGy4eWK2DwTjJ2` already created and checked out

---

### Phase 1: Configuration and Data Structures

- [x] 1.0 YAML Configuration Parsing
  - [x] 1.1 Research and choose YAML parser for Zig (chose kubkon/zig-yaml)
  - [x] 1.2 Create `src/config.zig` module
  - [x] 1.3 Define `ServiceConfig` struct with all fields (name, command, user, group, working_dir, env, restart)
  - [x] 1.4 Define `RestartPolicy` enum (always, on_failure, never)
  - [x] 1.5 Define `Config` struct to hold array of services
  - [x] 1.6 Implement `parseConfigFile()` function to read and parse YAML
  - [x] 1.7 Add validation for required fields (name, command)
  - [x] 1.8 Add validation for restart policy values
  - [x] 1.9 Implement clear error messages for parsing failures
  - [x] 1.10 Create tests in `src/config.zig` for valid and invalid configs
  - [x] 1.11 Test parsing ready for example/zei.yaml (requires build to verify)

- [x] 2.0 Service Data Structures and State Management
  - [x] 2.1 Create `src/service.zig` module
  - [x] 2.2 Define `ServiceState` enum (stopped, starting, running, stopping, failed, exited)
  - [x] 2.3 Define `ServiceInfo` struct (pid, state, start_time, restart_count, exit_code, exit_signal)
  - [x] 2.4 Create `src/service_manager.zig` module
  - [x] 2.5 Define `ServiceManager` struct with HashMap for services and PID tracking
  - [x] 2.6 Implement `init()` to create service manager
  - [x] 2.7 Implement `registerService()` to add service to registry
  - [x] 2.8 Implement `getServiceByName()` and `getServiceByPid()` to lookup services
  - [x] 2.9 Implement `updateState()` to change service state
  - [x] 2.10 Implement `incrementRestartCount()` for restart tracking
  - [x] 2.11 Implement `getAllRunningServices()` and helper methods
  - [x] 2.12 Create comprehensive tests in both modules

---

### Phase 2: Process Management

- [x] 3.0 Process Management and Spawning
  - [x] 3.1 Create `src/process.zig` module
  - [x] 3.2 Implement `parseCommand()` to convert command array to argv format
  - [x] 3.3 Implement `createPipes()` to set up stdout/stderr pipes
  - [x] 3.4 Implement `spawnProcess()` function using fork()
  - [x] 3.5 In child process: set working directory with chdir()
  - [x] 3.6 In child process: prepare and set environment variables
  - [x] 3.7 In child process: redirect stdout/stderr to pipes via dup2()
  - [x] 3.8 In child process: call execvpe() with command
  - [x] 3.9 In parent process: close unused pipe ends and return PID
  - [x] 3.10 Implement error handling for fork, chdir, execve failures
  - [x] 3.11 Create comprehensive tests in module (5 test cases)

- [x] 4.0 Privilege Escalation System
  - [x] 4.1 Create `src/privilege.zig` module
  - [x] 4.2 Implement `getCurrentUid()`, `getCurrentGid()`, `getCurrentEuid()`, `getCurrentEgid()` wrappers
  - [x] 4.3 Implement `lookupUser()` to get UID from username (parses /etc/passwd)
  - [x] 4.4 Implement `lookupGroup()` to get GID from group name (parses /etc/group)
  - [x] 4.5 Define `PrivilegeContext` struct to save original UID/GID/EUID/EGID
  - [x] 4.6 Implement `escalatePrivileges()` to save current state and setuid(0)
  - [x] 4.7 Implement `switchToUser()` to setgid() and setuid() to target user
  - [x] 4.8 Implement `dropPrivileges()` to restore original UID/GID
  - [x] 4.9 Add `verifySetuidConfiguration()` to check binary setup
  - [x] 4.10 Add safety checks: verify escalation, prevent re-escalation after drop
  - [x] 4.11 Create comprehensive tests in module (8 test cases, root tests skip gracefully)

---

### Phase 3: Monitoring and Lifecycle

- [x] 5.0 Service Monitoring and Restart Logic
  - [x] 5.1 Create `src/monitor.zig` module
  - [x] 5.2 Implement `shouldRestart()` function to evaluate restart policy
  - [x] 5.3 Check restart policy: always -> return true
  - [x] 5.4 Check restart policy: on_failure -> return true if exit_code != 0
  - [x] 5.5 Check restart policy: never -> return false
  - [x] 5.6 Implement `handleServiceExit()` to process service termination
  - [x] 5.7 Update service state based on exit (via markExited/markSignaled)
  - [x] 5.8 Increment restart counter if restarting
  - [x] 5.9 Return bool indicating if restart is needed
  - [x] 5.10 Log service exit and restart decisions
  - [x] 5.11 Create comprehensive tests in module (9 test cases)

- [x] 6.0 Process Reaping and Zombie Prevention
  - [x] 6.1 Create `src/reaper.zig` module
  - [x] 6.2 Implement `setupReaper()` to configure SIGCHLD handling
  - [x] 6.3 Create `reapProcesses()` function as main reaping loop
  - [x] 6.4 Call waitpid(-1, WNOHANG) in loop to reap all zombies
  - [x] 6.5 Match reaped PIDs to managed services via ServiceManager
  - [x] 6.6 Extract exit code and signal information using W.* macros
  - [x] 6.7 Update service info via monitor.handleServiceExit()
  - [x] 6.8 Handle orphaned processes (PIDs not in registry)
  - [x] 6.9 Log all reaped processes (managed and orphaned)
  - [x] 6.10 Implement safe reaping with proper error handling
  - [x] 6.11 Create comprehensive tests in module (9 test cases)

---

### Phase 4: Logging and I/O

- [ ] 7.0 Logging Infrastructure
  - [ ] 7.1 Create `src/logger.zig` module
  - [ ] 7.2 Define `LogCapture` struct to hold pipe FDs and buffer for each service
  - [ ] 7.3 Implement `createLogCapture()` to set up pipes for service
  - [ ] 7.4 Implement `setNonBlocking()` to make pipe FDs non-blocking
  - [ ] 7.5 Implement `readServiceLogs()` to read from pipe with non-blocking read
  - [ ] 7.6 Implement `prefixLogLine()` to add "[service-name] " prefix
  - [ ] 7.7 Implement `writeToStdout()` to output prefixed logs
  - [ ] 7.8 Implement buffer handling for partial lines (store incomplete lines)
  - [ ] 7.9 Implement `logLifecycleEvent()` for service start/stop/restart messages
  - [ ] 7.10 Handle EPIPE and other pipe errors gracefully
  - [ ] 7.11 Create `src/logger.test.zig` with logging tests

---

### Phase 5: Shutdown and Signals

- [ ] 8.0 Shutdown and Signal Handling
  - [ ] 8.1 Create `src/shutdown.zig` module
  - [ ] 8.2 Define `ShutdownState` struct to track shutdown progress
  - [ ] 8.3 Implement `initiateShutdown()` to begin shutdown sequence
  - [ ] 8.4 Implement `sendTermToAllServices()` to send SIGTERM to all running PIDs
  - [ ] 8.5 Implement `startShutdownTimer()` for timeout (e.g., 10 seconds)
  - [ ] 8.6 Implement `checkServicesExited()` to verify all services stopped
  - [ ] 8.7 Implement `sendKillToRemainingServices()` to send SIGKILL after timeout
  - [ ] 8.8 Implement `cleanupResources()` to close pipes and free memory
  - [ ] 8.9 Implement graceful exit with appropriate exit code
  - [ ] 8.10 Log all shutdown steps
  - [ ] 8.11 Create `src/shutdown.test.zig` with shutdown sequence tests

- [ ] 8.5 Signal Infrastructure (if needed as separate module)
  - [ ] 8.12 Create `src/signals.zig` if signal handling needs centralization
  - [ ] 8.13 Implement signalfd-based signal handling for Linux
  - [ ] 8.14 Register SIGTERM, SIGINT, SIGCHLD handlers
  - [ ] 8.15 Create signal dispatch mechanism for event loop

---

### Phase 6: Integration

- [x] 9.0 Main Event Loop Integration
  - [x] 9.1 Update `src/main.zig` to import all modules (config, service, process, privilege, monitor, reaper)
  - [x] 9.2 Add allocator setup with GPA and proper cleanup
  - [x] 9.3 Implement configuration loading using config.parseConfigFile()
  - [x] 9.4 Implement ServiceManager initialization and service registration
  - [x] 9.5 Implement startAllServices() to spawn all configured services
  - [x] 9.6 Set up signal handling with sigtimedwait (SIGTERM, SIGINT, SIGCHLD)
  - [x] 9.7 Implement main event loop with signal-based event handling
  - [x] 9.8 Integrated service output (pipes closed for MVP, ready for logging)
  - [x] 9.9 Add event handlers for SIGCHLD (reaping), SIGTERM/SIGINT (shutdown)
  - [x] 9.10 Implemented periodic zombie checking via timeout
  - [x] 9.11 Integrate shutdownAllServices() with SIGTERM/SIGKILL sequence
  - [x] 9.12 Add comprehensive startup banner and lifecycle logging
  - [x] 9.13 Handle errors with proper cleanup and error propagation

---

### Phase 7: Testing and Validation

- [ ] 10.0 Testing and Validation
  - [ ] 10.1 Run `zig build test` and fix any unit test failures
  - [ ] 10.2 Create `tests/` directory for integration tests
  - [ ] 10.3 Create `tests/fixtures/simple.yaml` with 1-2 services
  - [ ] 10.4 Create `tests/fixtures/multi-user.yaml` with services as different users
  - [ ] 10.5 Create `tests/fixtures/restart-policies.yaml` testing all restart policies
  - [ ] 10.6 Create `tests/integration.zig` for end-to-end tests
  - [ ] 10.7 Test: Start zei with simple config and verify services start
  - [ ] 10.8 Test: Verify service restart on failure (exit code != 0)
  - [ ] 10.9 Test: Verify service doesn't restart with policy=never
  - [ ] 10.10 Test: Send SIGTERM to zei and verify graceful shutdown
  - [ ] 10.11 Test: Verify zombie prevention with rapid service exits
  - [ ] 10.12 Test: Verify logs are properly prefixed with service names
  - [ ] 10.13 Test in Docker: Build container with setuid binary
  - [ ] 10.14 Test in Docker: Verify privilege escalation works for multi-user services
  - [ ] 10.15 Benchmark: Measure startup time with 10 services (<100ms target)
  - [ ] 10.16 Benchmark: Measure memory usage (<10MB RSS target)
  - [ ] 10.17 Benchmark: Measure binary size (<2MB target)
  - [ ] 10.18 Document test results in `DEVELOPMENT.md`

---

## Progress Tracking

### Completed Phases
- [x] Phase 0: Project setup
- [x] Phase 1: Configuration and Data Structures (Tasks 1-2) ✓
- [x] Phase 2: Process Management (Tasks 3-4) ✓
- [x] Phase 3: Monitoring and Lifecycle (Tasks 5-6) ✓
- [x] Phase 6: Integration (Task 9) ✓ **MVP FUNCTIONAL!**

### Current Phase
- [ ] Phase 7: Testing and Validation (Task 10)
  - Next: Test the MVP and validate functionality

### Skipped for MVP
- [ ] Phase 4: Logging and I/O (Task 7) - Can be added post-MVP
- [ ] Phase 5: Shutdown and Signals (Task 8) - Basic shutdown implemented in integration
- [ ] Phase 7: Testing and Validation (Task 10)

---

## Dependencies Between Tasks

**Sequential Dependencies:**
- Task 1 (config) must complete before Task 9 (integration)
- Task 2 (service manager) must complete before Task 5 (monitoring) and Task 9
- Task 3 (process) must complete before Task 9
- Task 4 (privilege) must complete before Task 3 can be fully functional
- Task 6 (reaper) needs Task 2 (service tracking)
- Task 7 (logger) needs Task 3 (pipes from processes)
- Task 8 (shutdown) needs Task 2 (service registry)
- Task 9 (integration) needs all other tasks 1-8
- Task 10 (testing) should run throughout but comprehensive tests need Task 9

**Suggested Implementation Order:**
1. Tasks 1-2 (Config + Service structures) - Foundation
2. Task 4 (Privilege) - Needed before spawning
3. Task 3 (Process spawning) - Core functionality
4. Task 7 (Logging) - Makes debugging easier
5. Task 5 (Monitoring) - Restart logic
6. Task 6 (Reaper) - Zombie prevention
7. Task 8 (Shutdown) - Graceful termination
8. Task 9 (Integration) - Tie it all together
9. Task 10 (Testing) - Validate everything

---

**Status:** Sub-tasks generated and ready for implementation!

**Next Step:** Begin with Task 1.0 (YAML Configuration Parsing) or review this task list.

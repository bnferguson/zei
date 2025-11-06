# Task List: zei MVP Implementation

## Relevant Files

*Note: This section will be completed after generating sub-tasks*

### Notes

- Unit tests should be placed alongside the code files they are testing
- Use `zig build test` to run all tests
- Use `zig test src/[file].zig` to run tests for a specific file

## Instructions for Completing Tasks

**IMPORTANT:** As you complete each task, you must check it off in this markdown file by changing `- [ ]` to `- [x]`. This helps track progress and ensures you don't skip any steps.

Example:
- `- [ ] 1.1 Read file` → `- [x] 1.1 Read file` (after completing)

Update the file after completing each sub-task, not just after completing an entire parent task.

## Tasks

- [ ] 0.0 Create feature branch
  - Note: We are already on branch `claude/pei-zig-port-011CUrkXKjcGy4eWK2DwTjJ2`

- [ ] 1.0 YAML Configuration Parsing
  - Implement YAML parser to read service definitions from configuration file
  - Parse and validate all required and optional service fields
  - Handle configuration errors gracefully with clear messages

- [ ] 2.0 Service Data Structures and State Management
  - Define service configuration structures
  - Implement service state tracking (PID, status, restart count, start time)
  - Create service registry/manager for all running services

- [ ] 3.0 Process Management and Spawning
  - Implement process spawning with user/group switching
  - Set up working directory and environment variables for services
  - Handle process execution errors

- [ ] 4.0 Privilege Escalation System
  - Implement setuid-based privilege escalation
  - Verify and validate target users/groups exist
  - Implement privilege dropping after operations

- [ ] 5.0 Service Monitoring and Restart Logic
  - Monitor running services and detect exits
  - Implement restart policies (always, on-failure, never)
  - Track service state changes and restart counts

- [ ] 6.0 Process Reaping and Zombie Prevention
  - Set up SIGCHLD signal handler
  - Implement waitpid-based reaping for all child processes
  - Handle both managed services and orphaned processes

- [ ] 7.0 Logging Infrastructure
  - Capture stdout/stderr from services via pipes
  - Implement log prefixing with service names
  - Stream logs to zei's stdout/stderr
  - Log service lifecycle events

- [ ] 8.0 Shutdown and Signal Handling
  - Implement graceful shutdown on SIGTERM/SIGINT
  - Send SIGTERM to all running services
  - Implement timeout and SIGKILL for unresponsive services

- [ ] 9.0 Main Event Loop Integration
  - Integrate all components into main event loop
  - Handle signal dispatching
  - Coordinate service monitoring and log streaming

- [ ] 10.0 Testing and Validation
  - Write unit tests for core modules
  - Create integration tests with example configurations
  - Test privilege escalation in container environment
  - Validate against success metrics from PRD

---

**Next Step:** Sub-tasks will be generated after user confirmation.

I have generated the high-level tasks based on your MVP requirements. These 10 parent tasks cover all the functional requirements from the PRD:

1. YAML parsing for configuration
2. Service data structures and state management
3. Process spawning
4. Privilege escalation
5. Service monitoring and restart logic
6. Process reaping (zombie prevention)
7. Logging infrastructure
8. Shutdown handling
9. Main event loop integration
10. Testing and validation

**Ready to generate the sub-tasks? Respond with 'Go' to proceed.**

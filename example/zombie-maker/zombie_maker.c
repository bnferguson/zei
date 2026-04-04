#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>

/* Creates orphaned child processes that become zombies until reaped by init. */
void create_zombie(void) {
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork failed");
        exit(1);
    }

    if (pid > 0) {
        /* Parent exits immediately, orphaning the child. */
        printf("Parent (PID: %d) created child (PID: %d)\n", getpid(), pid);
        exit(0);
    }

    /* Child keeps running — becomes orphan adopted by init. */
    printf("Child process (PID: %d) started\n", getpid());
    sleep(60);
    printf("Child process (PID: %d) exiting\n", getpid());
    exit(0);
}

int main(void) {
    printf("Zombie maker service started (PID: %d)\n", getpid());

    while (1) {
        create_zombie();
        sleep(30);
    }

    return 0;
}

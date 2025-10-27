#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

void open_tmp() {
    int fd;
    char *tmp = "/tmp/tempfile";
    fd = open(tmp, O_RDWR);
    if (fd != -1) {
        write(fd, "Hello", 5);
        close(fd);
    }
}

int main() {
    open_tmp();
    return 0;
}

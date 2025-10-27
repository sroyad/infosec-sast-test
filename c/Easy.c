#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    if (argc != 2) return 1;
    system(argv[1]); // Command Injection
    return 0;
}

#include <stdio.h>
#include <string.h>

void vulnerable(char *input) {
    char buffer[50];
    strcpy(buffer, input);
    printf("Input: %s\n", buffer);
}

int main(int argc, char *argv[]) {
    if (argc > 1)
        vulnerable(argv[1]);
    return 0;
}

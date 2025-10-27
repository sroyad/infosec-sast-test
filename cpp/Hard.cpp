#include <iostream>
#include <string>
using namespace std;

void printFormatted(string input) {
    printf(input.c_str()); // Format string vuln
}

int main(int argc, char* argv[]) {
    if (argc > 1)
        printFormatted(argv[1]);
    return 0;
}

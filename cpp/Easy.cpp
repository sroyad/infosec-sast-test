#include <iostream>
using namespace std;

int main(int argc, char* argv[]) {
    if (argc > 1)
        system(argv[1]); // Dangerous
    return 0;
}

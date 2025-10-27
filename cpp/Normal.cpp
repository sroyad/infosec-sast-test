#include <iostream>
#include <fstream>
#include <string>
using namespace std;

void insecure_file_access(const string &filename) {
    ifstream infile;
    infile.open(filename.c_str());
    if (!infile.fail()) {
        cout << "Opening file: " << filename << endl;
    }
    infile.close();
}

int main(int argc, char *argv[]) {
    if (argc > 1)
        insecure_file_access(argv[1]);
    return 0;
}

#include "cpp_verification.hpp"
#include <iostream>

int main(int argc, char **argv) {
    try {
        presage_verification::require(
            argc == 3 || argc == 4,
            "Usage: presage_check BUNDLE_DIR OUTPUTS.bin [PRECISION]");
        auto precision = argc == 4 ? presage_verification::integer(argv[3]) : 256;
        return presage_verification::check(argv[1], argv[2], std::cout, precision);
    } catch (const std::exception &error) {
        std::cerr << "Verification error: " << error.what() << '\n';
        return 3;
    }
}

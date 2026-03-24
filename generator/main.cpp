/*
 * Copyright (C) 2025-2026 Gerrit Pape (gerrit.pape@uni-paderborn.de)
 *
 * This file is part of PRESAGe.
 *
 * PRESAGe is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * PRESAGe is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with PRESAGe. If not, see <https://www.gnu.org/licenses/>.
 */
#include <sollya.h>

#include <iostream>
#include <sstream>
#include <string>

#include "types.hpp"
#include "Approximation.hpp"
#include "Generator.hpp"
#include "Rewriter.hpp"

int main(int argc, char **argv)
{
    // argc != 2: direct mode (toolchain precision function error [options])
    // argc == 2: pragma mode (single source file path)
    if (argc != 2 || std::string(argv[1]) == "-h" || std::string(argv[1]) == "--help") {
        verbose = true;
        sollya_lib_init();
        sollya_lib_set_verbosity(SOLLYA_CONST_UI64(0));

        Approximation approx(argc, argv);
        Generator gen(approx);

        sollya_lib_close();

        std::string name = gen.name();
        std::stringstream out_path;
        out_path << name << ".cpp";
        gen.write(out_path.str());

        std::stringstream resources_path;
        resources_path << name << ".csv";
        gen.write_resource_estimation(resources_path.str());

        std::cout << "output written to " << out_path.str() << std::endl;
        std::cout << "resource estimations written to " << resources_path.str() << std::endl;

    } else {
        verbose = false;

        std::string path(argv[1]);

        Rewriter rewriter(path);

    }
}

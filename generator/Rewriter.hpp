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
#pragma once

#include <sollya.h>

#include <string>
#include <vector>
#include <sstream>
#include <fstream>
#include <iostream>
#include <regex>
#include <filesystem>

#include "Approximation.hpp"
#include "Generator.hpp"

class Rewriter
{
public:
    Rewriter(std::string path_str) : path_str(path_str)
    {
        std::filesystem::path path(path_str);
        if (!std::filesystem::exists(path)) {
            throw std::invalid_argument(path_str);
        }

        std::ifstream f(path);
        std::string line;
        std::vector<std::string> lines;
        std::vector<std::string> approximation_paths;

        const std::regex approximation_pragma(R"(^\s*#\s*pragma\s+approximate\s+(.+)$)", std::regex_constants::icase);

        while (std::getline(f, line)) {
            std::smatch m;
            if (std::regex_match(line, m, approximation_pragma)) {
                std::vector<std::string> argvs;
                std::stringstream sstream (m[1].str());
                std::string method_to_replace;
                sstream >> method_to_replace;
                std::string arg;
                while (sstream >> arg) {
                    argvs.push_back(arg);
                }

                std::string line_containing_method;
                std::getline(f, line_containing_method);

                if (line_containing_method.contains(method_to_replace)) {
                    sollya_lib_init();
                    sollya_lib_set_verbosity(SOLLYA_CONST_UI64(0));
                    std::vector<char*> argv;
                    argv.push_back(const_cast<char*>(method_to_replace.c_str()));
                    for (auto &arg: argvs) {
                        argv.push_back(const_cast<char*>(arg.c_str()));
                    }
                    Approximation approx(argv.size(), argv.data());
                    Generator gen(approx);

                    std::stringstream new_name;
                    new_name << gen.name() << "::approximation";

                    line_containing_method.replace(line_containing_method.find(method_to_replace), method_to_replace.size(), new_name.str());

                    std::stringstream approximation_path_stream;
                    approximation_path_stream << gen.name() << ".cpp";
                    std::string approximation_path = approximation_path_stream.str();

                    gen.write(approximation_path);

                    std::stringstream resources_path_stream;
                    resources_path_stream << gen.name() << ".csv";

                    gen.write_resource_estimation(resources_path_stream.str());

                    approximation_paths.push_back(approximation_path);

                    sollya_lib_close();
                } else {
                    std::cout << method_to_replace << " not found, skipping approximation" << std::endl;
                }
                lines.push_back(line_containing_method);

            } else {
                lines.push_back(line);
            }
        }

        std::stringstream outpath_stream;
        outpath_stream << path_str << ".approximation.cpp";
        std::string outpath = outpath_stream.str();

        std::ofstream outfile(outpath);
        for (const auto &p: approximation_paths) {
            outfile << "#include \"" << p << "\"" << std::endl;
        }
        for (const auto &l: lines) {
            outfile << l << std::endl;
        }

    }

    std::string path_str;
};

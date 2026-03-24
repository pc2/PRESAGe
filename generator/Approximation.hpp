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
#include <mpfr.h>
#include <cxxopts.hpp>

#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <iomanip>

#include "types.hpp"
#include "float_utils.hpp"

class Approximation
{
public:
    cxxopts::ParseResult parse_options(int argc, char **argv)
    {
        cxxopts::Options options("./generator", "Function Approximation Generator\n\nUsage:\n  ./generator <filepath>\n\n    Searches the file for all occurrences of\n\n      #pragma approximation <function> <args>\n\n    and creates a new file <filepath>.approximation.cpp where the given\n    function is replaced by a call to the generated function, which is\n    included from a generated file.\n");

        options.add_options()
            ("toolchain", "Target toolchain (oneapi/vitis)", cxxopts::value<std::string>())
            ("precision", "Target format (single/double)", cxxopts::value<std::string>())
            ("function", "Function to approximate (sollya expression)", cxxopts::value<std::string>())
            ("error", "Error goal to achieve (sollya expression)", cxxopts::value<std::string>())
            ("r,range", "Approximation domain, must be list of two values", cxxopts::value<std::vector<std::string>>()->default_value("-1.0,1.0"))
            ("d,degree", "Approximation degree, can be single value or min,max", cxxopts::value<std::vector<uint64_t>>()->default_value("3,14"))
            ("s,split", "Ratios into which the input range is splitted", cxxopts::value<std::vector<uint64_t>>()->default_value("2,3,5,7"))
            ("t,errortype", "Type of error to optimize: relative or absolute", cxxopts::value<std::string>()->default_value("absolute"))
            ("b,boundary", "Behavior at boundary: poly, const or NaN", cxxopts::value<std::string>()->default_value("poly"))
            ("x,fix_segments", "Fix the number of segments, only useful for artifical analysis", cxxopts::value<uint64_t>()->default_value("0"))
            ("c,random_coefficients", "Use random coefficients", cxxopts::value<bool>()->default_value("false"))
            ("m,minimize", "Minimized resource for strategy selection: lut, ram or balanced", cxxopts::value<std::string>()->default_value("lut"))
            ("w,weights", "Weights for balanced usage minimization: LUTs, FFs, RAMs, DSPs", cxxopts::value<std::vector<double>>()->default_value("1.0,0.0,1.0,0.0"))
            ("v,verbose", "Verbose output for debugging", cxxopts::value<bool>()->default_value("false"))
            ("i,inline_functions", "May save resources, but decreases visiblity in reports", cxxopts::value<bool>()->default_value("false"))
            ("n,no_range_reductions", "Disable automatic detection of possbile range reductions", cxxopts::value<bool>()->default_value("false"))
            ("o,output-name", "Output name for generated files (default: auto-generated)", cxxopts::value<std::string>()->default_value(""))
            ("h,help", "Print usage")
            ;

        options.parse_positional({"toolchain", "precision", "function", "error"});

        options.positional_help("<toolchain> <precision> <function> <error>").show_positional_help();

        cxxopts::ParseResult result = options.parse(argc, argv);
        if (argc < 3 || result.count("help")) {
            std::cout << options.help() << std::endl;
            exit(EXIT_SUCCESS);
        }
        return result;
    }
    Approximation(int argc, char **argv) : Approximation(parse_options(argc, argv)) {}

    Approximation(cxxopts::ParseResult options)
    {
        std::string prec_str = options["precision"].as<std::string>();
        std::cout << prec_str << std::endl;
        precS = sollya_lib_parse_string(prec_str.c_str());

        if (sollya_lib_is_double_obj(precS)) {
            prec = 53;
            format = D;
        } else if (sollya_lib_is_single_obj(precS)) {
            prec = 24;
            format = SG;
        } else {
            throw std::invalid_argument("unsupported output format");
        }

        // for parsing the inputs
        sollya_lib_set_prec(SOLLYA_CONST_UI64(prec));

        std::vector<std::string> range = options["range"].as<std::vector<std::string>>();
        if (range.size() != 2) {
            throw std::invalid_argument("range only supports two values");
        }
        sollya_obj_t domMinS = sollya_lib_parse_string(range[0].c_str());
        mpfr_init2(domMin, prec);
        if (!sollya_lib_get_constant(domMin, domMinS)) {
            throw std::invalid_argument("domMin");
        }

        sollya_obj_t domMaxS = sollya_lib_parse_string(range[1].c_str());
        mpfr_init2(domMax, prec);
        if (!sollya_lib_get_constant(domMax, domMaxS)) {
            throw std::invalid_argument("domMax");
        }

        rangeS = sollya_lib_range_from_bounds(domMin, domMax);

        if (!sollya_lib_obj_is_range(rangeS)) {
            throw std::invalid_argument("building range from domMin and domMax");
        }

        fS = sollya_lib_parse_string(options["function"].as<std::string>().c_str());
        if (!sollya_lib_obj_is_function(fS)) {
            throw std::invalid_argument("f");
        }

        std::vector<uint64_t> degree = options["degree"].as<std::vector<uint64_t>>();

        if (degree.size() == 1) {
            degreeMin = degree[0];
            degreeMax = degree[0];
        } else if (degree.size() == 2) {
            degreeMin = degree[0];
            degreeMax = degree[1];
        } else {
            throw std::invalid_argument("degree only supports two values");
        }

        if (degreeMax < degreeMin) {
            throw std::invalid_argument("degreeMax < degreeMin");
        }

        split_ratios = options["split"].as<std::vector<uint64_t>>();

        sollya_obj_t errorS = sollya_lib_parse_string(options["error"].as<std::string>().c_str());
        mpfr_init2(error, prec);
        if (!sollya_lib_get_constant(error, errorS)) {
            throw std::invalid_argument("error");
        }

        errorTypeS = sollya_lib_parse_string(options["errortype"].as<std::string>().c_str());
        if (sollya_lib_is_absolute(errorTypeS)) {
            std::cout << "checking for absolute error" << std::endl;
        } else if (sollya_lib_is_relative(errorTypeS)) {
            std::cout << "checking for relative error" << std::endl;
        } else {
            throw std::invalid_argument("errorType");
        }

        std::string boundary_str = options["boundary"].as<std::string>();
        if (boundary_str == "poly") {
            boundary = is_poly;
        } else if (boundary_str == "const") {
            boundary = is_const;
        } else if (boundary_str == "NaN") {
            boundary = is_nan;
        } else {
            throw std::invalid_argument("unsupported boundary");
        }

        std::string toolchain_str = options["toolchain"].as<std::string>();
        if (toolchain_str == "vitis") {
            toolchain = is_vitis;
        } else if (toolchain_str == "oneapi") {
            toolchain = is_oneapi;
        } else {
            throw std::invalid_argument("unsupported toolchain");
        }

        std::string minimize_str = options["minimize"].as<std::string>();
        if (minimize_str == "lut") {
            minimize = lut;
        } else if (minimize_str == "ram") {
            minimize = ram;
        } else if (minimize_str == "balanced") {
            minimize = balanced;
        } else {
            throw std::invalid_argument("unsupported minimize strategy");
        }

        fix_segments = options["fix_segments"].as<uint64_t>();
        if ((fix_segments > 0) && (degreeMin != degreeMax)) {
            throw std::invalid_argument("fix_segments only works with single degree");
        }
        random_coefficients = options["random_coefficients"].as<bool>();
        verbose = options["verbose"].as<bool>();
        weights = options["weights"].as<std::vector<double>>();
        if (weights.size() != 4) {
            throw std::invalid_argument("weights must be four: LUTs,FFs,RAMs,DSPs");
        }
        inline_functions = options["inline_functions"].as<bool>();
        no_range_reductions = options["no_range_reductions"].as<bool>();
        output_name = options["output-name"].as<std::string>();

        // should be enough for checks
        uint64_t working_precision = 8;
        sollya_lib_set_prec(SOLLYA_CONST_UI64(working_precision));

        sollya_obj_t resultS = sollya_lib_evaluate(fS, rangeS);
        sollya_obj_t resultSupS = sollya_lib_sup(resultS);

        mpfr_t resultSup;
        mpfr_init2(resultSup, working_precision);
        sollya_lib_get_constant(resultSup, resultSupS);
        if (mpfr_nan_p(resultSup)) {
            throw std::invalid_argument("function is not defined on this domain");
        }

        // checking infinite slope
        sollya_obj_t diffS = sollya_lib_diff(fS);

        // TODO: use supnorm
        sollya_obj_t boundS = sollya_lib_infnorm(diffS, rangeS, NULL);
        sollya_obj_t boundSupS = sollya_lib_sup(boundS);

        mpfr_t boundSup;
        mpfr_init2(boundSup, working_precision);
        sollya_lib_get_constant(boundSup, boundSupS);
        if (mpfr_inf_p(boundSup)) {
            sollya_lib_printf("%b has infinite slope, fpminimax will fail\n", fS);
        } else {
            sollya_lib_printf("%b has finite slope\n", fS);
        }

        // Detect function properties to apply range reductions:
        // - exp: reduce to [-ln(2)/2, ln(2)/2] via exp(x) = 2^k * exp(r)
        // - cosh/sinh: rewrite as combination of exp(x) and exp(-x)
        if (no_range_reductions) {
            exponential = is_none;
        } else  {
            sollya_obj_t expS = SOLLYA_EXP(SOLLYA_X_);
            if (sollya_lib_is_true(sollya_lib_cmp_equal(fS, expS))) {
                exponential = is_exp;
                boundary = is_all;
                std::cout << "detected exp" << std::endl;
            } else {
                sollya_obj_t coshS = SOLLYA_COSH(SOLLYA_X_);
                if (sollya_lib_is_true(sollya_lib_cmp_equal(fS, coshS))) {
                    exponential = is_cosh;
                    boundary = is_all;
                    std::cout << "detected cosh" << std::endl;
                    fS = SOLLYA_EXP(SOLLYA_X_);
                } else {
                    sollya_obj_t sinhS = SOLLYA_SINH(SOLLYA_X_);
                    if (sollya_lib_is_true(sollya_lib_cmp_equal(fS, sinhS))) {
                        exponential = is_sinh;
                        boundary = is_all;
                        std::cout << "detected sinh" << std::endl;
                        fS = SOLLYA_EXP(SOLLYA_X_);
                    } else {
                        exponential = is_none;
                    }
                }
            }
        }

        if (exponential == is_none) {
            if (no_range_reductions) {
                is_periodic = false;
                symmetry = neither;
            } else {
                // Check periodicity: if f(x) == f(x + P) over the range,
                // add a modulo reduction step and only approximate one period
                sollya_obj_t periodS = sollya_lib_sub(domMaxS, domMinS);

                sollya_obj_t fShiftedS = sollya_lib_substitute(fS, SOLLYA_ADD(SOLLYA_X_, periodS));

                sollya_obj_t fPeriodS = SOLLYA_SUB(fS, fShiftedS);

                // TODO: use supnorm
                sollya_obj_t periodDiffS = sollya_lib_infnorm(fPeriodS, rangeS, NULL);
                sollya_obj_t periodDiffInfS = sollya_lib_inf(periodDiffS);

                mpfr_t periodDiffInf;
                mpfr_init2(periodDiffInf, working_precision);
                sollya_lib_get_constant(periodDiffInf, periodDiffInfS);
                is_periodic = mpfr_zero_p(periodDiffInf);
                if (is_periodic) {
                    boundary = is_all;
                    mpfr_init2(period, prec);
                    sollya_lib_get_constant(period, periodS);
                    sollya_lib_printf("%b is periodic over %b\n", fS, rangeS);
                    mpfr_init2(periodMin, prec);
                    mpfr_set(periodMin, domMin, MPFR_RNDN);
                    mpfr_init2(periodMax, prec);
                    mpfr_set(periodMax, domMax, MPFR_RNDN);
                } else {
                    sollya_lib_printf("%b is not periodic over %b\n", fS, rangeS);
                }

                // Check symmetry: if f(x) == f(-x) (even) or f(x) == -f(-x) (odd),
                // only approximate the positive half and add a sign check
                sollya_obj_t fIS = sollya_lib_substitute(fS, SOLLYA_NEG(SOLLYA_X_));
                if (!sollya_lib_obj_is_function(fS)) {
                    throw std::invalid_argument("fI");
                }

                sollya_obj_t fEvenS = SOLLYA_SUB(fS, fIS);
                if (!sollya_lib_obj_is_function(fS)) {
                    throw std::invalid_argument("fEven");
                }
                sollya_obj_t evenDiffS = sollya_lib_dirtyinfnorm(fEvenS, rangeS);
                mpfr_t symmetryDiff;
                mpfr_init2(symmetryDiff, working_precision);
                sollya_lib_get_constant(symmetryDiff, evenDiffS);
                if (mpfr_zero_p(symmetryDiff)) {
                    sollya_lib_printf("%b is even\n", fS);
                    symmetry = even;
                } else {
                    sollya_obj_t fOddS = SOLLYA_ADD(fS, fIS);
                    if (!sollya_lib_obj_is_function(fS)) {
                        throw std::invalid_argument("fOdd");
                    }

                    sollya_obj_t oddDiffS = sollya_lib_dirtyinfnorm(fOddS, rangeS);
                    sollya_lib_get_constant(symmetryDiff, oddDiffS);
                    if (mpfr_zero_p(symmetryDiff)) {
                        sollya_lib_printf("%b is odd\n", fS);
                        symmetry = odd;
                    } else {
                        sollya_lib_printf("%b has no symmetry\n", fS);
                        symmetry = neither;
                    }
                }

                if (symmetry == even || symmetry == odd) {
                    // TODO: maybe check if -domMin > domMax ?
                    // TODO: what if function is not around zero? two ranges?
                    mpfr_set_zero(domMin, +1);
                    rangeS = sollya_lib_range_from_bounds(domMin, domMax);

                    if (!sollya_lib_obj_is_range(rangeS)) {
                        throw std::invalid_argument("building range from domMin and domMax after symmetry check");
                    }
                }
            }
        } else {
            // For exp/cosh/sinh: approximate exp(x) on [-ln(2)/2, ln(2)/2]
            // and reconstruct via range reduction at evaluation time
            symmetry = neither;
            is_periodic = false;

            mpfr_const_log2(domMax, MPFR_RNDN);
            mpfr_div_ui(domMax, domMax, 2, MPFR_RNDN);
            mpfr_neg(domMin, domMax, MPFR_RNDN);
        }
        // very high internal precision for fpminimax
        sollya_lib_set_prec(SOLLYA_CONST_UI64(512));

        sollya_lib_clear_obj(errorS);
    }

    Approximation(const Approximation& original, mpfr_t new_domMin, mpfr_t new_domMax) :
        prec(original.prec),
        precS(sollya_lib_copy_obj(original.precS)),
        format(original.format),
        fS(sollya_lib_copy_obj(original.fS)),
        symmetry(original.symmetry),
        degreeMin(original.degreeMin),
        degreeMax(original.degreeMax),
        split_ratios(original.split_ratios),
        is_periodic(original.is_periodic),
        exponential(original.exponential),
        errorTypeS(sollya_lib_copy_obj(original.errorTypeS)),
        toolchain(original.toolchain),
        boundary(original.boundary),
        minimize(original.minimize),
        fix_segments(original.fix_segments),
        random_coefficients(original.random_coefficients),
        weights(original.weights),
        inline_functions(original.inline_functions),
        no_range_reductions(original.no_range_reductions),
        output_name(original.output_name)
    {
        mpfr_init2(domMin, prec);
        mpfr_set(domMin, new_domMin, MPFR_RNDN);

        mpfr_init2(domMax, prec);
        mpfr_set(domMax, new_domMax, MPFR_RNDN);

        rangeS = sollya_lib_range_from_bounds(domMin, domMax);

        mpfr_init2(error, prec);
        mpfr_set(error, original.error, MPFR_RNDN);

        if (is_periodic) {
            mpfr_init2(period, prec);
            mpfr_set(period, original.period, MPFR_RNDN);
            mpfr_init2(periodMin, prec);
            mpfr_set(periodMin, original.periodMin, MPFR_RNDN);
            mpfr_init2(periodMax, prec);
            mpfr_set(periodMax, original.periodMax, MPFR_RNDN);
        }
    }

    std::vector<Approximation> split(uint32_t intervals)
    {
        std::vector<Approximation> approximations;
        if (intervals == 1) {
            approximations.push_back(Approximation(*this, domMin, domMax));
            return approximations;
        }
        mpfr_t boundaries[intervals + 1];

        mpfr_init2(boundaries[0], prec);
        mpfr_set(boundaries[0], domMin, MPFR_RNDN);

        if (in_one_binade(domMin, domMax)) {
            mpfr_t length;
            mpfr_init2(length, prec);
            mpfr_sub(length, domMax, domMin, MPFR_RNDN);

            mpfr_t step;
            mpfr_init2(step, prec);
            mpfr_div_ui(step, length, intervals, MPFR_RNDN);

            for (uint32_t i = 1; i < intervals; i++) {
                mpfr_init2(boundaries[i], prec);
                mpfr_add(boundaries[i], boundaries[i - 1], step, MPFR_RNDN);
            }
        } else {
            mpfr_exp_t exp_min = mpfr_get_exp(domMin);
            mpfr_exp_t exp_max = mpfr_get_exp(domMax);

            mpfr_exp_t sign_min = mpfr_sgn(domMin);
            mpfr_exp_t sign_max = mpfr_sgn(domMax);

            bool min_is_power_of_two = is_power_of_two(domMin);
            bool max_is_power_of_two = is_power_of_two(domMax);

            intervals = 2;
            mpfr_init2(boundaries[1], prec);
            if (sign_min < 0 && sign_max > 0) {
                mpfr_set_zero(boundaries[1], 1);
            } else {
                mpfr_exp_t exp_middle;
                if (sign_min >= 0) {
                    exp_middle = exp_max - 1;
                    if (max_is_power_of_two) {
                        exp_middle -= 1;
                    }
                } else {
                    exp_middle = exp_min - 1;
                    if (min_is_power_of_two) {
                        exp_middle -= 1;
                    }
                }
                mpfr_set_si_2exp(boundaries[1], 1, exp_middle, MPFR_RNDN);
                if (sign_min < 0) {
                    mpfr_neg(boundaries[1], boundaries[1], MPFR_RNDN);
                }
            }
        }

        mpfr_init2(boundaries[intervals], prec);
        mpfr_set(boundaries[intervals], domMax, MPFR_RNDN);

        for (uint32_t i = 0; i < intervals; i++) {
            approximations.push_back(Approximation(*this, boundaries[i], boundaries[i + 1]));
        }

        return approximations;
    }

    void print_error(sollya_obj_t eS)
    {
        sollya_obj_t errorSupS = sollya_lib_sup(eS);
        double error;
        sollya_lib_get_constant_as_double(&error, errorSupS);
        std::cout << "error sup: " << error << std::endl;
    }

    void fpminimax(int degree)
    {
        //check if range is too small, indicator for dead end
        mpfr_t diff;
        mpfr_init2(diff, prec);

        mpfr_sub(diff, domMin, domMax, MPFR_RNDN);
        mpfr_abs(diff, diff, MPFR_RNDN);

        mpfr_t threshold;
        mpfr_init2(threshold, prec);
        mpfr_set_ui_2exp(threshold, 1, -prec, MPFR_RNDN);

        if (mpfr_cmp(diff, threshold) <= 0) {
            throw std::logic_error("range too small");
        }

        sollya_obj_t formatsS = sollya_lib_build_end_elliptic_list(sollya_lib_copy_obj(precS), NULL);

        if (!sollya_lib_obj_is_end_elliptic_list(formatsS)) {
            printf("formats obj is not a end elliptic list");
        }

        if (verbose) {
            sollya_lib_printf("approximating %b on", fS);
            mpfr_printf(" [%.4Rf;%.4Rf] ", domMin, domMax);
            sollya_lib_printf("with degree %i\n", degree);
        }

        sollya_obj_t degreeS = SOLLYA_CONST_UI64(degree);

        pS = sollya_lib_fpminimax(fS, degreeS, formatsS, rangeS, sollya_lib_floating(), errorTypeS, NULL);

        if (sollya_lib_obj_is_error(pS)) {
            throw std::logic_error("fpminimax failed");
        }

        sollya_lib_clear_obj(formatsS);
   }

    bool reaches_error(int degree)
    {
        sollya_obj_t coeffS = sollya_lib_coeff(pS, SOLLYA_CONST_UI64(degree));
        sollya_obj_t pRoundedS;
        if (format == SG) {
            pRoundedS = sollya_lib_build_function_single(coeffS);
        } else if (format == D) {
            pRoundedS = sollya_lib_build_function_double(coeffS);
        }

        for (uint32_t i = 0; i < degree; i++) {
            sollya_obj_t coeffS = sollya_lib_coeff(pS, SOLLYA_CONST_UI64(degree - i - 1));
            if (format == SG) {
                pRoundedS =
                    sollya_lib_build_function_single(
                        SOLLYA_ADD(
                            SOLLYA_MUL(
                                pRoundedS,
                                SOLLYA_X_
                            ),
                            coeffS
                        )
                    );
            } else if (format == D) {
                pRoundedS =
                    sollya_lib_build_function_double(
                        SOLLYA_ADD(
                            SOLLYA_MUL(
                                pRoundedS,
                                SOLLYA_X_
                            ),
                            coeffS
                        )
                    );
            }
        }
        if (!sollya_lib_obj_is_function(pRoundedS)) {
            throw std::logic_error("pRounded not a function");
        }

        //sollya_lib_printf("pRounded = %b\n", pRoundedS);

        sollya_obj_t diffS = SOLLYA_SUB(fS, pRoundedS);

        sollya_obj_t errorRoundedS = sollya_lib_infnorm(diffS, rangeS, NULL);

        //print_error(errorRoundedS);

        sollya_obj_t errorRoundedSupS = sollya_lib_sup(errorRoundedS);

        mpfr_t errorRoundedSup;
        mpfr_init2(errorRoundedSup, prec);

        sollya_lib_get_constant(errorRoundedSup, errorRoundedSupS);

        bool rounded_is_reaching_error = mpfr_cmp(error, errorRoundedSup) > 0;

        errorS = sollya_lib_supnorm(pS, fS, rangeS, errorTypeS, sollya_lib_constant(error));

        if (sollya_lib_obj_is_error(errorS)) {
            throw std::logic_error("supnorm failed");
        }

        //print_error(errorS);

        sollya_obj_t errorSupS = sollya_lib_sup(errorS);

        mpfr_t errorSup;
        mpfr_init2(errorSup, prec);

        sollya_lib_get_constant(errorSup, errorSupS);

        bool is_reaching_error = mpfr_cmp(error, errorSup) > 0;

        sollya_lib_clear_obj(errorSupS);
        mpfr_clear(errorSup);

        return is_reaching_error;// && rounded_is_reaching_error;
    }

    friend std::ostream& operator<<(std::ostream& os, const Approximation& obj)
    {
        char range_str[8196];
        sollya_lib_snprintf(range_str, 8196, "%b", obj.rangeS);
        char f_str[8196];
        sollya_lib_snprintf(f_str, 8196, "%b", obj.fS);
        char p_str[8196];
        sollya_lib_snprintf(p_str, 8196, "%b", obj.pS);
        char error_str[8196];
        sollya_lib_snprintf(error_str, 8196, "%b", obj.errorS);

        os << f_str << " in " << range_str << std::endl
            << " approximated by " <<  p_str << std::endl
            << " with error" << std::endl
            << error_str << std::endl;

        return os;
    }

    ~Approximation()
    {
        //TODO: clean up without errors
        //mpfr_clear(domMin);
        //mpfr_clear(domMax);
        //sollya_lib_clear_obj(rangeS);
        //sollya_lib_clear_obj(fS);
        //sollya_lib_clear_obj(pS);
        //sollya_lib_clear_obj(errorS);
    }

    mpfr_prec_t prec;
    sollya_obj_t precS;
    Format format;
    mpfr_t domMin, domMax;
    sollya_obj_t rangeS;
    sollya_obj_t fS, pS;
    sollya_obj_t errorS;
    sollya_obj_t errorTypeS;
    Symmetry symmetry;
    uint64_t degreeMin;
    uint64_t degreeMax;
    std::vector<uint64_t> split_ratios;
    mpfr_t error, period, periodMin, periodMax;
    bool is_periodic;
    Exponential exponential;
    Toolchain toolchain;
    Boundary boundary;
    uint64_t fix_segments;
    bool random_coefficients;
    Minimize minimize;
    std::vector<double> weights;
    bool inline_functions;
    bool no_range_reductions;
    std::string output_name;
};

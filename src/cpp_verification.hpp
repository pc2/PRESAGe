#pragma once

// Host-only verification. Evaluator kernels have no dependency on this header.
#include <algorithm>
#include <fstream>
#include <gmpxx.h>
#include <limits>
#include <map>
#include <mpfr.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace presage_verification {

inline void require(bool condition, const std::string &message) {
    if (!condition)
        throw std::runtime_error(message);
}

inline std::vector<std::string> fields(const std::string &line) {
    std::vector<std::string> result;
    std::size_t start = 0;
    do {
        auto end = line.find('\t', start);
        result.push_back(line.substr(start, end - start));
        if (end == std::string::npos)
            break;
        start = end + 1;
    } while (true);
    return result;
}

inline long integer(const std::string &text) {
    require(!text.empty(), "empty integer");
    auto start = text[0] == '-' ? 1u : 0u;
    require(start < text.size() &&
                text.find_first_not_of("0123456789", start) == std::string::npos,
            "invalid integer: " + text);
    std::size_t used = 0;
    auto value = std::stol(text, &used);
    require(used == text.size(), "invalid integer");
    return value;
}

inline mpz_class big_integer(const std::string &text) {
    auto start = !text.empty() && text[0] == '-' ? 1u : 0u;
    require(start < text.size() &&
                text.find_first_not_of("0123456789", start) == std::string::npos,
            "invalid big integer");
    return mpz_class(text, 10);
}

inline mpq_class rational(const std::string &text) {
    auto slash = text.find('/');
    require(slash != std::string::npos, "expected numerator/denominator");
    auto numerator = big_integer(text.substr(0, slash));
    auto denominator = big_integer(text.substr(slash + 1));
    require(denominator > 0, "nonpositive denominator");
    mpq_class value(numerator, denominator);
    value.canonicalize();
    return value;
}

struct Format {
    bool floating = false;
    long width = 0;
    long exponent_bits = 0;
    long fraction_bits = 0;
    bool signed_fixed = false;

    std::size_t bytes() const { return static_cast<std::size_t>(1 + (width - 1) / 8); }
};

inline Format format(const std::vector<std::string> &f, const std::string &name) {
    require(f.size() == 5 && f[0] == name, "invalid " + name + " format");
    Format result;
    if (f[1] == "float") {
        result.floating = true;
        result.exponent_bits = integer(f[2]);
        result.fraction_bits = integer(f[3]);
        require(result.exponent_bits >= 2 &&
                    result.exponent_bits <= std::numeric_limits<long>::digits - 1 &&
                    result.fraction_bits >= 1 && f[4] == "0" &&
                    result.fraction_bits <
                        std::numeric_limits<long>::max() - result.exponent_bits,
                "invalid floating dimensions");
        result.width = 1 + result.exponent_bits + result.fraction_bits;
        require(result.fraction_bits <= std::numeric_limits<long>::max() -
                                            ((1L << (result.exponent_bits - 1)) - 1),
                "floating exponent exceeds long");
    } else {
        require(f[1] == "fixed", "unknown format");
        result.width = integer(f[2]);
        auto integer_bits = integer(f[3]);
        require(result.width >= 1 && integer_bits >= 1 && integer_bits <= result.width &&
                    (f[4] == "0" || f[4] == "1"),
                "invalid fixed dimensions");
        result.fraction_bits = result.width - integer_bits;
        result.signed_fixed = f[4] == "1";
    }
    return result;
}

inline void validate_word(const mpz_class &word, const Format &f) {
    require(word >= 0 && (word == 0 || mpz_sizeinbase(word.get_mpz_t(), 2) <=
                                           static_cast<std::size_t>(f.width)),
            "nonzero padding or oversized word");
}

inline mpz_class word(const std::string &text, const Format &f) {
    require(text.size() > 2 && text.substr(0, 2) == "0x" &&
                text.find_first_not_of("0123456789abcdefABCDEF", 2) == std::string::npos,
            "invalid hexadecimal word");
    mpz_class result(text.substr(2), 16);
    validate_word(result, f);
    return result;
}

inline mpz_class read_word(std::istream &input, const Format &f, bool little) {
    std::vector<unsigned char> bytes(f.bytes());
    input.read(reinterpret_cast<char *>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
    require(input.gcount() == static_cast<std::streamsize>(bytes.size()),
            "missing or truncated binary word");
    mpz_class result;
    mpz_import(result.get_mpz_t(), bytes.size(), little ? -1 : 1, 1, 0, 0, bytes.data());
    validate_word(result, f);
    return result;
}

inline std::string hex(const mpz_class &word, const Format &f) {
    auto text = word.get_str(16);
    auto digits = static_cast<std::size_t>(1 + (f.width - 1) / 4);
    return "0x" + std::string(digits - text.size(), '0') + text;
}

struct Number {
    mpz_class significand = 0;
    long exponent = 0;
    std::string kind = "finite";
};

// Compare exact dyadics without expanding astronomical exponent gaps. If their
// binades coincide, the required shift is bounded by the stored significands.
inline int compare_dyadics(mpz_class a, long ae, mpz_class b, long be) {
    int as = mpz_sgn(a.get_mpz_t()), bs = mpz_sgn(b.get_mpz_t());
    if (as != bs)
        return as < bs ? -1 : 1;
    if (as == 0)
        return 0;
    a = abs(a);
    b = abs(b);
    auto aw = mpz_sizeinbase(a.get_mpz_t(), 2), bw = mpz_sizeinbase(b.get_mpz_t(), 2);
    mpz_class atop = mpz_class(ae) + mpz_class(aw), btop = mpz_class(be) + mpz_class(bw);
    int comparison = mpz_cmp(atop.get_mpz_t(), btop.get_mpz_t());
    if (comparison == 0) {
        if (aw < bw)
            a <<= bw - aw;
        else
            b <<= aw - bw;
        comparison = mpz_cmp(a.get_mpz_t(), b.get_mpz_t());
    }
    return as < 0 ? -comparison : comparison;
}

struct ExactEndpoint {
    mpz_class numerator = 0, denominator = 1;
    long exponent = 0;
    int infinity = 0;
};

inline ExactEndpoint exact_endpoint(const std::string &text) {
    ExactEndpoint result;
    if (text == "+inf" || text == "-inf")
        result.infinity = text == "-inf" ? -1 : 1;
    else if (auto at = text.find('@'); at != std::string::npos) {
        result.numerator = big_integer(text.substr(0, at));
        result.exponent = integer(text.substr(at + 1));
    } else {
        auto q = rational(text);
        result.numerator = q.get_num();
        result.denominator = q.get_den();
    }
    return result;
}

inline int compare_endpoints(const std::string &first, const std::string &second) {
    auto a = exact_endpoint(first), b = exact_endpoint(second);
    if (a.infinity || b.infinity)
        return a.infinity < b.infinity ? -1 : a.infinity > b.infinity ? 1 : 0;
    return compare_dyadics(a.numerator * b.denominator, a.exponent,
                           b.numerator * a.denominator, b.exponent);
}

inline Number decode(const mpz_class &bits, const Format &f) {
    Number result;
    result.significand = bits;
    result.exponent = -f.fraction_bits;
    bool negative = mpz_tstbit(bits.get_mpz_t(), static_cast<mp_bitcnt_t>(f.width - 1));
    if (!f.floating) {
        if (f.signed_fixed && negative)
            result.significand -= mpz_class(1) << f.width;
        return result;
    }
    mpz_class fraction = bits & ((mpz_class(1) << f.fraction_bits) - 1);
    mpz_class field = (bits >> f.fraction_bits) & ((mpz_class(1) << f.exponent_bits) - 1);
    long bias = (1L << (f.exponent_bits - 1)) - 1;
    if (field == (mpz_class(1) << f.exponent_bits) - 1) {
        result.kind = fraction == 0 ? (negative ? "-inf" : "+inf") : "nan";
        return result;
    }
    result.significand = fraction;
    if (field != 0)
        result.significand += mpz_class(1) << f.fraction_bits;
    result.exponent = (field == 0 ? 1 - bias : field.get_si() - bias) - f.fraction_bits;
    if (negative)
        result.significand = -result.significand;
    return result;
}

class Real {
  public:
    mpfr_t value;
    explicit Real(mpfr_prec_t precision) { mpfr_init2(value, precision); }
    Real(const Real &other) {
        mpfr_init2(value, mpfr_get_prec(other.value));
        mpfr_set(value, other.value, MPFR_RNDN);
    }
    Real &operator=(const Real &other) {
        if (this == &other)
            return *this;
        mpfr_set_prec(value, mpfr_get_prec(other.value));
        mpfr_set(value, other.value, MPFR_RNDN);
        return *this;
    }
    ~Real() { mpfr_clear(value); }
};

class ExponentRange {
    mpfr_exp_t minimum = mpfr_get_emin(), maximum = mpfr_get_emax();

  public:
    ExponentRange() {
        require(mpfr_set_emin(MPFR_EMIN_MIN) == 0 && mpfr_set_emax(MPFR_EMAX_MAX) == 0,
                "could not extend MPFR exponent range");
    }
    ~ExponentRange() {
        mpfr_set_emin(minimum);
        mpfr_set_emax(maximum);
    }
};

inline void set(Real &result, const Number &number, mpfr_rnd_t rounding) {
    require(number.kind == "finite", "expected finite number");
    mpfr_set_z(result.value, number.significand.get_mpz_t(), rounding);
    mpfr_mul_2si(result.value, result.value, number.exponent, rounding);
}

inline void endpoint(Real &result, const std::string &text, mpfr_rnd_t rounding) {
    if (text == "+inf" || text == "-inf") {
        mpfr_set_inf(result.value, text == "-inf" ? -1 : 1);
    } else if (auto at = text.find('@'); at != std::string::npos) {
        set(result,
            Number{big_integer(text.substr(0, at)), integer(text.substr(at + 1)), "finite"},
            rounding);
    } else {
        auto q = rational(text);
        mpfr_set_q(result.value, q.get_mpq_t(), rounding);
    }
}

inline std::string exact(const Real &number) {
    if (mpfr_inf_p(number.value))
        return mpfr_sgn(number.value) < 0 ? "-inf" : "+inf";
    require(!mpfr_nan_p(number.value), "invalid error enclosure");
    if (mpfr_zero_p(number.value))
        return "0@0";
    mpz_class significand;
    auto exponent = mpfr_get_z_2exp(significand.get_mpz_t(), number.value);
    return significand.get_str() + "@" + std::to_string(exponent);
}

inline std::string verdict(const Real &lower, const Real &upper, const mpq_class &budget) {
    if (mpfr_cmp_q(upper.value, budget.get_mpq_t()) <= 0)
        return "passed";
    if (mpfr_cmp_q(lower.value, budget.get_mpq_t()) > 0)
        return "failed";
    return "unresolved";
}

// Exact comparisons resolve equality with a rational budget, even when the
// rational error itself has no finite binary expansion.
inline std::string rational_verdict(const Real &y, const mpq_class &lo, const mpq_class &hi,
                                    const mpq_class &budget) {
    mpq_class lower = hi - budget, upper = lo + budget;
    if (mpfr_cmp_q(y.value, lower.get_mpq_t()) >= 0 &&
        mpfr_cmp_q(y.value, upper.get_mpq_t()) <= 0)
        return "passed";
    lower = lo - budget;
    upper = hi + budget;
    if (mpfr_cmp_q(y.value, lower.get_mpq_t()) < 0 ||
        mpfr_cmp_q(y.value, upper.get_mpq_t()) > 0)
        return "failed";
    return "unresolved";
}

inline std::string quote(const std::string &text) {
    std::string result = "\"";
    for (unsigned char c : text) {
        if (c == '"' || c == '\\')
            result += '\\';
        require(c >= 32 && c != 127, "control character in report field");
        result += static_cast<char>(c);
    }
    return result + '"';
}

struct Case {
    long index = 0;
    std::map<std::string, std::string> data;
    bool bit_match = false;
};

inline void write_case(std::ostream &output, const Case &item) {
    output << "index = " << item.index << '\n';
    output << "bit_match = " << (item.bit_match ? "true" : "false") << '\n';
    for (const auto &[key, value] : item.data)
        output << key << " = " << quote(value) << '\n';
}

// Read one case at a time; the report keeps only witnesses and problems.
inline int check(const std::string &directory, const std::string &outputs_path,
                 std::ostream &report, mpfr_prec_t precision = 256) {
    require(precision >= 32 && precision <= MPFR_PREC_MAX, "invalid checker precision");
    ExponentRange exponent_range;
    std::ifstream cases(directory + "/cases.tsv");
    std::ifstream inputs(directory + "/inputs.bin", std::ios::binary);
    std::ifstream expected(directory + "/expected.bin", std::ios::binary);
    std::ifstream outputs(outputs_path, std::ios::binary);
    require(cases && inputs && expected && outputs, "could not open verification files");
    auto line = [&]() {
        std::string text;
        require(static_cast<bool>(std::getline(cases, text)), "truncated cases file");
        return fields(text);
    };
    require(line() == std::vector<std::string>{"PRESAGE_VERIFICATION", "1"},
            "unsupported verification schema");
    auto infmt = format(line(), "input"), outfmt = format(line(), "output");
    require(outfmt.fraction_bits <= MPFR_PREC_MAX - 8, "output precision exceeds MPFR");
    auto output_precision = outfmt.floating ? outfmt.fraction_bits + 8 : outfmt.width;
    require(output_precision <= MPFR_PREC_MAX, "output precision exceeds MPFR");
    precision = std::max(precision, static_cast<mpfr_prec_t>(output_precision));
    auto order = line();
    require(order.size() == 2 && order[0] == "byteorder" &&
                (order[1] == "little" || order[1] == "big"),
            "invalid byte order");
    bool little = order[1] == "little";
    auto allowance = line();
    require(allowance.size() == 2 && allowance[0] == "absolute_error",
            "missing error target");
    auto target = rational(allowance[1]);
    require(target > 0, "nonpositive error target");
    auto count_field = line();
    require(count_field.size() == 2 && count_field[0] == "count", "missing case count");
    long count = integer(count_field[1]);
    require(count >= 0, "negative case count");
    require(line() == std::vector<std::string>{"index", "input_bits", "expected_bits",
                                               "reference_status", "reference_bits",
                                               "reference_lower", "reference_upper",
                                               "reference_precision", "certificate_bound",
                                               "branch"},
            "invalid case columns");
    Real maximum_lower(precision), maximum_upper(precision);
    mpfr_set_zero(maximum_lower.value, 1);
    mpfr_set_zero(maximum_upper.value, 1);
    Case lower_witness, upper_witness;
    bool have_maximum = false;
    std::map<std::string, long> counts{
        {"tested", count},         {"bit_mismatches", 0},        {"numeric_checked", 0},
        {"special_checked", 0},    {"outside_domain", 0},        {"accuracy_passed", 0},
        {"accuracy_failed", 0},    {"accuracy_unresolved", 0},   {"certificate_passed", 0},
        {"certificate_failed", 0}, {"certificate_unresolved", 0}};
    std::ostringstream issues;
    for (long index = 1; index <= count; ++index) {
        auto row = line();
        require(row.size() == 10 && integer(row[0]) == index,
                "invalid case index or columns");
        Case item;
        item.index = index;
        const std::vector<std::string> keys{
            "input_bits",          "expected_bits",     "reference_status",
            "reference_bits",      "reference_lower",   "reference_upper",
            "reference_precision", "certificate_bound", "branch"};
        for (std::size_t i = 0; i < keys.size(); ++i)
            item.data[keys[i]] = row[i + 1];
        require(integer(row[7]) >= 0, "negative reference precision");
        if (row[4] != "-")
            word(row[4], outfmt);
        if (row[8] != "-")
            require(rational(row[8]) >= 0, "negative certificate bound");
        auto input_bits = word(row[1], infmt), expected_bits = word(row[2], outfmt);
        require(read_word(inputs, infmt, little) == input_bits,
                "input binary/case mismatch");
        require(read_word(expected, outfmt, little) == expected_bits,
                "expected binary/case mismatch");
        auto actual_bits = read_word(outputs, outfmt, little);
        item.bit_match = actual_bits == expected_bits;
        item.data["output_bits"] = hex(actual_bits, outfmt);
        if (!item.bit_match)
            ++counts["bit_mismatches"];
        auto actual = decode(actual_bits, outfmt);
        auto status = row[3];
        std::string accuracy = "unresolved", certificate = "not_applicable";
        bool numeric = row[5] != "-" || row[6] != "-";
        require((row[5] == "-") == (row[6] == "-"), "incomplete reference enclosure");
        require(status == "resolved" || status == "special" || status == "domain_error" ||
                    status == "outside_domain" || status == "unresolved" ||
                    status == "evaluation_failed" || status == "overflow" ||
                    status == "nonfinite_output",
                "unknown reference status");
        bool special = status == "special" || status == "domain_error";
        bool special_match = true;
        if (special && row[4] != "-") {
            ++counts["special_checked"];
            special_match = actual_bits == word(row[4], outfmt);
            accuracy = special_match ? "passed" : "failed";
        }
        if (numeric) {
            ++counts["numeric_checked"];
            Real lo(precision), hi(precision), y(precision), lower(precision),
                upper(precision), scratch(precision);
            require(compare_endpoints(row[5], row[6]) <= 0, "reversed reference enclosure");
            endpoint(lo, row[5], MPFR_RNDD);
            endpoint(hi, row[6], MPFR_RNDU);
            require(mpfr_cmp(lo.value, hi.value) <= 0, "reversed reference enclosure");
            bool rational_reference = row[5].find('/') != std::string::npos &&
                                      row[6].find('/') != std::string::npos;
            mpq_class exact_lo, exact_hi;
            if (rational_reference) {
                exact_lo = rational(row[5]);
                exact_hi = rational(row[6]);
                require(exact_lo <= exact_hi, "reversed rational reference enclosure");
            }
            mpfr_set_zero(lower.value, 1);
            mpfr_set_inf(upper.value, 1);
            if (actual.kind == "finite") {
                set(y, actual, MPFR_RNDN); // Enough precision to hold every output bit.
                require(mpfr_number_p(y.value), "output exceeds checker exponent range");
            }
            if (actual.kind != "finite") {
                // A nonfinite evaluator output cannot satisfy a finite absolute target.
                mpfr_set_inf(lower.value, 1);
            } else {
                mpfr_sub(scratch.value, lo.value, y.value, MPFR_RNDD);
                if (mpfr_cmp(scratch.value, lower.value) > 0)
                    mpfr_set(lower.value, scratch.value, MPFR_RNDN);
                mpfr_sub(scratch.value, y.value, hi.value, MPFR_RNDD);
                if (mpfr_cmp(scratch.value, lower.value) > 0)
                    mpfr_set(lower.value, scratch.value, MPFR_RNDN);
                mpfr_sub(upper.value, y.value, lo.value, MPFR_RNDU);
                mpfr_sub(scratch.value, hi.value, y.value, MPFR_RNDU);
                if (mpfr_cmp(scratch.value, upper.value) > 0)
                    mpfr_set(upper.value, scratch.value, MPFR_RNDN);
            }
            accuracy = verdict(lower, upper, target);
            if (rational_reference && actual.kind == "finite")
                accuracy = rational_verdict(y, exact_lo, exact_hi, target);
            if (!special_match)
                accuracy = "failed";
            if (row[8] != "-") {
                auto bound = rational(row[8]);
                require(bound >= 0, "negative certificate bound");
                certificate = verdict(lower, upper, bound);
                if (rational_reference && actual.kind == "finite")
                    certificate = rational_verdict(y, exact_lo, exact_hi, bound);
                ++counts["certificate_" + certificate];
            }
            item.data["error_lower"] = exact(lower);
            item.data["error_upper"] = exact(upper);
            item.data["accuracy"] = accuracy;
            item.data["certificate"] = certificate;
            if (!have_maximum || mpfr_cmp(lower.value, maximum_lower.value) > 0) {
                maximum_lower = lower;
                lower_witness = item;
            }
            if (!have_maximum || mpfr_cmp(upper.value, maximum_upper.value) > 0) {
                maximum_upper = upper;
                upper_witness = item;
            }
            have_maximum = true;
        } else if (status == "outside_domain") {
            ++counts["outside_domain"];
            accuracy = "outside_domain";
        } else if (accuracy == "unresolved") {
            // Include missing references in the maximum enclosure. A finite
            // maximum over only the resolved subset would overstate coverage.
            item.data["error_lower"] = "0@0";
            item.data["error_upper"] = "+inf";
            if (row[8] != "-") {
                certificate = "unresolved";
                ++counts["certificate_unresolved"];
            }
            item.data["accuracy"] = accuracy;
            item.data["certificate"] = certificate;
            if (!have_maximum)
                lower_witness = item;
            if (!have_maximum || !mpfr_inf_p(maximum_upper.value))
                upper_witness = item;
            mpfr_set_inf(maximum_upper.value, 1);
            have_maximum = true;
        }
        item.data["accuracy"] = accuracy;
        item.data["certificate"] = certificate;
        if (accuracy != "outside_domain")
            ++counts["accuracy_" + accuracy];
        if (!item.bit_match || accuracy == "failed" || accuracy == "unresolved" ||
            certificate == "failed" || certificate == "unresolved") {
            issues << "\n[[issues]]\n";
            write_case(issues, item);
        }
    }
    require(inputs.peek() == std::char_traits<char>::eof() &&
                expected.peek() == std::char_traits<char>::eof() &&
                outputs.peek() == std::char_traits<char>::eof(),
            "extra binary output or bundle data");
    require(cases.peek() == std::char_traits<char>::eof(), "extra case records");
    require(!inputs.bad() && !expected.bad() && !outputs.bad() && !cases.bad(),
            "verification file read failed");
    bool failed = counts["bit_mismatches"] || counts["accuracy_failed"] ||
                  counts["certificate_failed"];
    bool unresolved =
        count == 0 || counts["accuracy_unresolved"] || counts["certificate_unresolved"];
    auto status = failed ? "failed" : unresolved ? "unresolved" : "passed";
    report << "schema = \"presage-verification-report\"\nschema_version = 1\nstatus = "
           << quote(status) << "\nchecker_precision = " << precision << '\n';
    report << "absolute_error = " << quote(allowance[1]) << '\n';
    report << "\n[counts]\n";
    for (const auto &[key, value] : counts)
        report << key << " = " << value << '\n';
    if (have_maximum) {
        report << "\n[maximum_error]\nlower = " << quote(exact(maximum_lower))
               << "\nupper = " << quote(exact(maximum_upper))
               << "\nlower_witness_index = " << lower_witness.index
               << "\nupper_witness_index = " << upper_witness.index << '\n';
        report << "\n[maximum_lower_witness]\n";
        write_case(report, lower_witness);
        report << "\n[maximum_upper_witness]\n";
        write_case(report, upper_witness);
    }
    report << issues.str();
    require(static_cast<bool>(report), "could not write verification report");
    return failed ? 1 : unresolved ? 2 : 0;
}

} // namespace presage_verification

cmake_minimum_required(VERSION 3.24)
project(PRESAGeCPU LANGUAGES CXX)
include(CTest)
find_program(PRESAGE_JULIA julia REQUIRED)
set(PRESAGE_PLAN "" CACHE FILEPATH "Existing evaluator plan; empty generates a fresh erf candidate")
set(PRESAGE_EVALUATION separate CACHE STRING "Horner arithmetic: separate or fma")
file(GLOB PRESAGE_JULIA_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.jl")
set(generated "${CMAKE_CURRENT_BINARY_DIR}/generated")
if(PRESAGE_PLAN)
  set(source "${PRESAGE_PLAN}")
  set(options)
else()
  set(source erf)
  set(options "--evaluation=${PRESAGE_EVALUATION}")
endif()
add_custom_command(
  OUTPUT "${generated}/evaluator.hpp" "${generated}/evaluate.cpp" "${generated}/plan.toml"
  COMMAND "${PRESAGE_JULIA}" --startup-file=no "--project=${CMAKE_CURRENT_SOURCE_DIR}"
          "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate.jl" "${source}" "${generated}" ${options}
  DEPENDS ${PRESAGE_JULIA_SOURCES} "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate.jl" ${PRESAGE_PLAN}
  VERBATIM)
add_executable(presage_cpu "${generated}/evaluate.cpp" "${generated}/evaluator.hpp")
target_compile_features(presage_cpu PRIVATE cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(presage_cpu PRIVATE -ffp-contract=off -fno-fast-math -frounding-math)
else()
  message(FATAL_ERROR "The CPU verification build currently requires Clang or GCC")
endif()
if(BUILD_TESTING)
  add_test(NAME cpu_conformance COMMAND "${PRESAGE_JULIA}" --startup-file=no
    "--project=${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/verify_cpu.jl"
    "${generated}/plan.toml" "$<TARGET_FILE:presage_cpu>")
endif()

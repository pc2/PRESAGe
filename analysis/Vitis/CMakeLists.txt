cmake_minimum_required(VERSION 3.27)
project(AnalysisVitis)

set(PART_STR xcu280-fsvh2892-2L-e CACHE STRING "part string")
set(PLATFORM_STR xilinx_u280_gen3x16_xdma_1_202211_1 CACHE STRING "platform string")

set(BUILD_TARGET hw CACHE STRING "build_target")
set(EXTRA_ARGS "" CACHE STRING "extra args for pragma")

set(KERNEL_FREQ_HZ 300 CACHE STRING "freqhz option")
# synth flags
set(COMMFLAGS --platform ${PLATFORM_STR} --target ${BUILD_TARGET} --save-temps --debug)
set(HLSCFLAGS --compile ${COMMFLAGS} -I${CMAKE_SOURCE_DIR}/..)
set(LINKFLAGS --link --optimize 3 ${COMMFLAGS})

set(PRECISIONS half single double)

set(all_kernel_outputs "")

function(build_kernel_and_bitstream_targets bitstream_name bitstream_type kernel_names_arg kernel_executables_arg)
    set(kernel_names ${${kernel_names_arg}})
    list(LENGTH kernel_names num_kernel_names)
    set(kernel_executables ${${kernel_executables_arg}})
    list(LENGTH kernel_executables num_kernel_executables)

    if (NOT num_kernel_names EQUAL num_kernel_executables)
        message(FATAL_ERROR, "number of kernel names does not match number of kernel executables")
    endif()

    set(kernel_outputs "")
    set(kernel_float_outputs "")

    math(EXPR last_i_kernel "${num_kernel_names} - 1")

    foreach(i_kernel RANGE ${last_i_kernel})
        list(GET kernel_names ${i_kernel} kernel_name)
        list(GET kernel_executables ${i_kernel} kernel_executable)

        set(kernel_output "${kernel_name}_${BUILD_TARGET}.xo")
        if(NOT "${kernel_name}" MATCHES "uint")
            list(APPEND kernel_float_outputs ${kernel_output})
        endif()
        list(APPEND kernel_outputs ${kernel_output})

        set(kernel_file "")
        if(kernel_executable STREQUAL " ")
            set(kernel_file "${CMAKE_BINARY_DIR}/kernels/${kernel_name}.cpp")
        else()
            set(generator_input "${CMAKE_BINARY_DIR}/kernels/${kernel_name}.cpp")
            set(kernel_file "${generator_input}.approximation.cpp")
            add_custom_command(
                OUTPUT "${kernel_file}"
                COMMAND ${CMAKE_SOURCE_DIR}/../generator/build/${kernel_executable} ${generator_input}
                DEPENDS "${generator_input}"
                COMMENT "Running generator on ${generator_input}"
            )
        endif()
        add_custom_command(
            OUTPUT
                "${kernel_output}"
            COMMAND
                v++ ${HLSCFLAGS}
                    --temp_dir _x_${kernel_name}_${BUILD_TARGET}
                    --kernel ${kernel_name}
                    --output ${kernel_output}
                    --include ${CMAKE_SOURCE_DIR}/hls
                    --include ${CMAKE_BINARY_DIR}
                    ${kernel_file}
            DEPENDS
                ${kernel_file} 
            COMMENT
                "Building ${kernel_output}"
        )
        add_custom_target(${kernel_name} DEPENDS ${kernel_output})
    endforeach()

    add_custom_target(${bitstream_name}_reports DEPENDS ${kernel_outputs})

    set(all_kernel_outputs ${all_kernel_outputs} ${kernel_outputs} PARENT_SCOPE)

    set(bitstream_output "${bitstream_name}_${BUILD_TARGET}.xclbin")

    add_custom_command(
        OUTPUT "${bitstream_output}"
        COMMAND
            v++ ${LINKFLAGS}
                --temp_dir _x_${bitstream_name}_${BUILD_TARGET}
                --config ${CMAKE_SOURCE_DIR}/configs/${bitstream_name}.cfg
                --output ${bitstream_output}
                --include ${CMAKE_SOURCE_DIR}/hls
                ${kernel_float_outputs}
        DEPENDS ${kernel_float_outputs}
        COMMAND_EXPAND_LISTS
        COMMENT "Synthesizing ${bitstream_output}"
    )

    add_custom_target(${bitstream_name}_xclbin DEPENDS ${bitstream_output})

    set(bitstream_output_all "${bitstream_name}_all_${BUILD_TARGET}.xclbin")

    add_custom_command(
        OUTPUT "${bitstream_output_all}"
        COMMAND
            v++ ${LINKFLAGS}
                --temp_dir _x_${bitstream_name}_${BUILD_TARGET}
                --config ${CMAKE_SOURCE_DIR}/configs/${bitstream_name}.cfg
                ${extra_clock_flags}
                --vivado.impl.strategies "ALL"
                --advanced.param compiler.multiStrategiesWaitOnAllRuns=1
                --output ${bitstream_output}
                --include ${CMAKE_SOURCE_DIR}/hls
                ${kernel_float_outputs}
        DEPENDS ${kernel_float_outputs}
        COMMAND_EXPAND_LISTS
        COMMENT "Synthesizing ${bitstream_output_all}"
    )

    add_custom_target(${bitstream_name}_xclbin_all_strategies DEPENDS ${bitstream_output_all})

endfunction()

function(generate_kernel_files input_file names_arg operations_arg types_arg pragmas_arg)
    set(names ${${names_arg}})
    set(operations ${${operations_arg}})
    set(types ${${types_arg}})
    set(pragmas ${${pragmas_arg}})

    list(LENGTH names num_names)
    list(LENGTH operations num_operations)
    list(LENGTH types num_types)
    list(LENGTH pragmas num_pragmas)

    if(NOT num_names EQUAL num_operations)
        message(FATAL_ERROR "Number of names does not match with number of operations")
    endif()
    if(NOT num_names EQUAL num_types)
        message(FATAL_ERROR "Number of names does not match with number of types")
    endif()
    if(NOT num_names EQUAL num_pragmas)
        message(FATAL_ERROR "Number of names does not match with number of pragmas")
    endif()

    math(EXPR last_i "${num_names} - 1")
    
    foreach(i RANGE ${last_i})
        list(GET names ${i} name)
        list(GET operations ${i} function)
        list(GET types ${i} type)
        list(GET pragmas ${i} pragma)

        if (NOT ${EXTRA_ARGS} STREQUAL "")
            set(pragma "${pragma} ${EXTRA_ARGS}")
        endif()

        configure_file(${input_file} ${CMAKE_BINARY_DIR}/kernels/${name}.cpp)
    endforeach()
endfunction()

file(READ "../config.json" config)
string(JSON num_bitstreams LENGTH "${config}" "groups")

file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/kernels)

math(EXPR last_i "${num_bitstreams} - 1")
foreach(i RANGE ${last_i})
    set(kernel_names "")
    set(kernel_operations "")
    set(kernel_precisions "")
    set(kernel_pragmas "")
    set(kernel_executables "")

    string(JSON bitstream_name GET "${config}" "groups" "${i}" "name")
    string(JSON bitstream_type GET "${config}" "groups" "${i}" "type")
    string(JSON bitstream_operations ERROR_VARIABLE op_err GET "${config}" "groups" "${i}" "operations")

    if(NOT op_err)
        string(JSON num_operations LENGTH "${bitstream_operations}")
        math(EXPR last_i_op "${num_operations} - 1")
        foreach(i_op RANGE ${last_i_op})
            string(JSON op GET "${bitstream_operations}" "${i_op}")
            foreach(prec ${PRECISIONS})
                list(APPEND kernel_names "${op}_${prec}")
                if (${prec} STREQUAL "double")
                    list(APPEND kernel_operations "${op}")
                    list(APPEND kernel_precisions "double")
                elseif(${prec} STREQUAL "single")
                    list(APPEND kernel_operations "${op}f")
                    list(APPEND kernel_precisions "float")
                elseif(${prec} STREQUAL "half")
                    list(APPEND kernel_operations "half_${op}")
                    list(APPEND kernel_precisions "half")
                endif()
                list(APPEND kernel_pragmas " ")
                list(APPEND kernel_executables " ")
            endforeach()
            if(bitstream_type STREQUAL "binary")
                foreach(int_width RANGE "1" "64}")
                    list(APPEND kernel_names "${op}_uint${int_width}")
                    list(APPEND kernel_operations "${op}<${int_width}>")
                    list(APPEND kernel_precisions "ap_uint<${int_width}>")
                    list(APPEND kernel_pragmas " ")
                    list(APPEND kernel_executables " ")
                endforeach()
            endif()
        endforeach()
    else()
        string(JSON bitstream_toolchain GET "${config}" "groups" "${i}" "toolchain")
        if(${bitstream_type} STREQUAL "unitary" AND ${bitstream_toolchain} STREQUAL "Vitis")
            string(JSON bitstream_approximations GET "${config}" "groups" "${i}" "approximations")
            string(JSON num_approximations LENGTH "${bitstream_approximations}")
            math(EXPR last_i_app "${num_approximations} - 1")
            foreach(i_app RANGE ${last_i_app})
                string(JSON name GET "${bitstream_approximations}" "${i_app}" "name") 
                list(APPEND kernel_names "${name}")
                string(JSON operation GET "${bitstream_approximations}" "${i_app}" "operation") 
                list(APPEND kernel_operations "${operation}")
                string(JSON precision GET "${bitstream_approximations}" "${i_app}" "precision") 
                list(APPEND kernel_precisions "${precision}")
                string(JSON pragma GET "${bitstream_approximations}" "${i_app}" "pragma") 
                list(APPEND kernel_pragmas "${pragma}")
                string(JSON executable GET "${bitstream_approximations}" "${i_app}" "executable") 
                list(APPEND kernel_executables "${executable}")
            endforeach()
        else()
            continue()
        endif()
    endif()

    generate_kernel_files(${CMAKE_SOURCE_DIR}/hls/${bitstream_type}.cpp.in kernel_names kernel_operations kernel_precisions kernel_pragmas)

    build_kernel_and_bitstream_targets("${bitstream_name}" "${bitstream_type}" kernel_names kernel_executables)
endforeach()

add_custom_target(reports DEPENDS ${all_kernel_outputs})

include(FetchContent)

FetchContent_declare(json
    GIT_REPOSITORY https://github.com/nlohmann/json
    GIT_TAG v3.11.3)

FetchContent_GetProperties(json)
if(NOT json_POPULATED)
	message(STATUS "Fetching nlohmann/json")
	FetchContent_Populate(json)
	set(json_SOURCE_DIR ${json_SOURCE_DIR})
endif()

find_package(OpenMP REQUIRED)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_compile_options(-Wall -g)

add_executable(main host/main.cpp)

include_directories(main PRIVATE $ENV{XILINX_XRT}/include ${json_SOURCE_DIR}/include)

target_link_directories(main PRIVATE $ENV{XILINX_XRT}/lib)

target_link_libraries(main PRIVATE xrt_coreutil uuid OpenMP::OpenMP_CXX)

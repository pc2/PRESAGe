cmake_minimum_required(VERSION 3.27)
project(AnalysisOneAPI)

set(CMAKE_VERBOSE_MAKEFILE TRUE)

set(CMAKE_CXX_COMPILER icpx)
set(EXTRA_ARGS "" CACHE STRING "extra args for pragma")

set(COMMON_FLAGS -fintelfpga -fsycl -qactypes -qopenmp)
set(COMP_FLAGS ${COMMON_FLAGS} -Wall -I${CMAKE_SOURCE_DIR}/device -I${CMAKE_SOURCE_DIR}/host -I${CMAKE_BINARY_DIR})
set(REPORT_FLAGS ${COMP_FLAGS} -Xshardware -fsycl-link=early -DREPORT)
set(DEVICE_FLAGS ${COMP_FLAGS} -fsycl-link=image)

set(report_outputs "")
function(generate_report_target operation type half_disabled generator)
    set(local_report_flags "${REPORT_FLAGS}")
    if (half_disabled)
        list(APPEND local_report_flags "-DDISABLE_HALF" )
    endif()

    set(report_output "${operation}_report")  
    if(generator STREQUAL " ")
        set(report_input "${CMAKE_BINARY_DIR}/kernels/${operation}.cpp")
    else()
        set(generator_input "${CMAKE_BINARY_DIR}/kernels/${operation}.cpp")
        set(report_input "${CMAKE_BINARY_DIR}/kernels/${operation}.cpp.approximation.cpp")

        add_custom_command(
            OUTPUT "${report_input}"
            COMMAND ${CMAKE_SOURCE_DIR}/../generator/build/${generator} ${generator_input}
            DEPENDS "${generator_input}"
            COMMENT "Running generator on ${generator_input}"
        )
    endif()
    add_custom_command(
        OUTPUT
            "${report_output}.prj"
        COMMAND
            icpx ${local_report_flags} ${report_input} -o ${report_output}
        DEPENDS
            ${report_input}
        COMMENT
            "Building ${operation} report"
    )
    add_custom_target(${operation}_report DEPENDS "${report_output}.prj")
    set(report_outputs ${report_outputs} ${report_output} PARENT_SCOPE)
endfunction()

function(generate_targets operation type half_disabled generator emu)
    set(local_device_flags "${DEVICE_FLAGS}")
    if (half_disabled)
        set(local_device_flags -DDISABLE_HALF ${local_device_flags})
    endif()
    if (emu)
        set(local_device_flags -DDISABLE_HALF -DEMULATION ${local_device_flags})
        set(device_output "${operation}_emu.a")
        set(device_target "${operation}_device_emu")
    else()
        set(local_device_flags -Xshardware ${local_device_flags})
        set(device_output "${operation}.a")
        set(device_target "${operation}_device")
    endif()

    if (generator STREQUAL " ")
        set(device_input "${CMAKE_BINARY_DIR}/kernels/${operation}.cpp")
    else()
        # Assuming generate_report_target was already run!
        set(device_input "${CMAKE_BINARY_DIR}/kernels/${operation}.cpp.approximation.cpp")
    endif()
    add_custom_command(
        OUTPUT
            "${device_output}"
        COMMAND
            icpx ${local_device_flags} ${device_input} -o ${device_output}
        DEPENDS
            ${device_input}
        COMMENT
            "Building ${device_output}"
    )
    add_custom_target(${device_target} DEPENDS ${device_output})

    set(local_host_flags "${COMP_FLAGS}")
    if (half_disabled)
        set(local_host_flags -DDISABLE_HALF ${local_host_flags})
    endif()
    if (emu)
        set(local_host_flags -DDISABLE_HALF -DEMULATION ${local_host_flags})
        set(host_output "${operation}_emu.o")
        set(host_target "${operation}_host_emu")
    else()
        set(host_output "${operation}.o")
        set(host_target "${operation}_host")
    endif()
    set(host_input "${CMAKE_SOURCE_DIR}/host/main.cpp")
    add_custom_command(
        OUTPUT
            "${host_output}"
        COMMAND
            icpx ${local_host_flags} ${host_input} -c -o ${host_output}
        DEPENDS
            ${host_input} ${CMAKE_SOURCE_DIR}/../common.hpp

        COMMENT
            "Building ${host_output}"
    )
    add_custom_target(${host_target} DEPENDS ${host_output})

    set(local_link_flags "${COMMON_FLAGS}")
    if (emu)
        set(link_output "${operation}.emu")
        set(link_target "${operation}_link_emu")
    else()
        set(link_output "${operation}.fpga")
        set(link_target "${operation}_link")
    endif()

    add_custom_command(
        OUTPUT
            "${link_output}"
        COMMAND
            icpx ${local_link_flags} ${host_output} ${device_output} -o ${link_output}
        DEPENDS
            ${host_output} ${device_output}
        COMMENT
            "Building ${link_output}"
    )
    add_custom_target(${link_target} DEPENDS ${link_output})
endfunction()

file(READ "../config.json" config)
string(JSON num_groups LENGTH "${config}" "groups")
string(JSON num_unsupported_by_half LENGTH "${config}" "unsupported_by_ap_float")
string(JSON unsupported_by_half GET "${config}" "unsupported_by_ap_float")

set(operations "")
set(types "")
set(num_operations "0")
set(half_disableds "")

math(EXPR last_i_groups "${num_groups} - 1")
foreach(i RANGE ${last_i_groups})
    string(JSON operation_type GET "${config}" "groups" "${i}" "type")
    string(JSON group_operations ERROR_VARIABLE op_err GET "${config}" "groups" "${i}" "operations")
    if (op_err)
        continue()
    endif()
    string(JSON num_group_operations LENGTH "${group_operations}")
    math(EXPR last_i_op "${num_group_operations} - 1")
    foreach(i_op RANGE ${last_i_op})
        string(JSON op GET "${group_operations}" "${i_op}")
        list(APPEND operations "${op}")
        list(APPEND types "${operation_type}")
        math(EXPR num_operations "${num_operations} + 1")
        math(EXPR last_i_disabled "${num_unsupported_by_half} - 1")
        set(found_disabled NO)
        foreach(i_disabled RANGE ${last_i_disabled})
            string(JSON disabled GET "${unsupported_by_half}" "${i_disabled}")
            if ("${op}" STREQUAL "${disabled}")
                set(found_disabled YES)
            endif()
        endforeach()
        list(APPEND half_disableds "${found_disabled}")
    endforeach()
endforeach()

math(EXPR last_i_ops "${num_operations} - 1")
foreach(i RANGE ${last_i_ops})
    list(GET operations ${i} operation)
    list(GET types ${i} type)
    list(GET half_disableds ${i} half_disabled)

    configure_file("${CMAKE_SOURCE_DIR}/device/${type}.cpp.in" ${CMAKE_BINARY_DIR}/kernels/${operation}.cpp) 

    generate_report_target(${operation} ${type} ${half_disabled} " ")

    generate_targets(${operation} ${type} ${half_disabled} " " YES)
    generate_targets(${operation} ${type} ${half_disabled} " " NO)
endforeach()

foreach(i RANGE ${last_i_groups})
    string(JSON group_name GET "${config}" "groups" "${i}" "name")
    if("${group_name}" STREQUAL "all_oneAPI_approximations")
        string(JSON approximations GET "${config}" "groups" "${i}" "approximations")
        string(JSON num_approximations LENGTH "${config}" "groups" "${i}" "approximations")
        math(EXPR last_i_app "${num_approximations} - 1")
        foreach(i_app RANGE ${last_i_app})
            string(JSON name GET "${approximations}" "${i_app}" "name")
            string(JSON operation GET "${approximations}" "${i_app}" "operation")
            string(JSON half_pragma GET "${approximations}" "${i_app}" "half_pragma")
            string(JSON single_pragma GET "${approximations}" "${i_app}" "single_pragma")
            string(JSON double_pragma GET "${approximations}" "${i_app}" "double_pragma")
            string(JSON executable GET "${approximations}" "${i_app}" "executable")

            if (NOT ${EXTRA_ARGS} STREQUAL "")
                set(single_pragma "${single_pragma} ${EXTRA_ARGS}")
                set(double_pragma "${double_pragma} ${EXTRA_ARGS}")
            endif()

            configure_file("${CMAKE_SOURCE_DIR}/device/unitary.cpp.in" "${CMAKE_BINARY_DIR}/kernels/${name}.cpp")

            math(EXPR last_i_disabled "${num_unsupported_by_half} - 1")
            set(half_disabled NO)
            foreach(i_disabled RANGE ${last_i_disabled})
                string(JSON disabled GET "${unsupported_by_half}" "${i_disabled}")
                if ("${op}" STREQUAL "${disabled}")
                set(half_disabled YES)
            endif()
            endforeach()
 
            generate_report_target(${name} unitary ${half_disabled} ${executable})
            generate_targets(${name} unitary ${half_disabled} ${executable} YES)
            generate_targets(${name} unitary ${half_disabled} ${executable} NO)
        endforeach()
    endif()
endforeach()
add_custom_target(reports DEPENDS ${report_outputs})

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

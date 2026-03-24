cmake_minimum_required(VERSION 3.24 FATAL_ERROR)
project(Generator VERSION 0.1)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(ExternalProject)
include(FetchContent)

set(LOCAL_PREFIX ${CMAKE_BINARY_DIR}/local)
set(LOCALE_ENV LC_ALL=C LC_CTYPE=C)

# --- cxxopts (header-only, CMake) ---
FetchContent_Declare(cxxopts
    GIT_REPOSITORY https://github.com/jarro2783/cxxopts.git
    GIT_TAG        v3.2.1
)
FetchContent_MakeAvailable(cxxopts)

# --- fplll (autotools, sollya dependency) ---
ExternalProject_Add(fplll_ext
    URL               https://github.com/fplll/fplll/releases/download/5.5.0/fplll-5.5.0.tar.gz
    CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env <SOURCE_DIR>/configure --prefix=${LOCAL_PREFIX} --without-qd
    BUILD_COMMAND     make -j
    INSTALL_COMMAND   make install
    BUILD_IN_SOURCE   TRUE
)

# --- sollya (autotools, depends on fplll) ---
ExternalProject_Add(sollya_ext
    URL               https://www.sollya.org/releases/sollya-8.0/sollya-8.0.tar.bz2
    CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env
        "PKG_CONFIG_PATH=${LOCAL_PREFIX}/lib/pkgconfig"
        "CPPFLAGS=-I${LOCAL_PREFIX}/include"
        "LDFLAGS=-L${LOCAL_PREFIX}/lib"
        <SOURCE_DIR>/configure --prefix=${LOCAL_PREFIX}
    BUILD_COMMAND     make -j
    INSTALL_COMMAND   make install
    BUILD_IN_SOURCE   TRUE
    DEPENDS           fplll_ext
)

# --- generator ---
add_executable(generator main.cpp)

add_dependencies(generator sollya_ext)

target_include_directories(generator PRIVATE
    ${LOCAL_PREFIX}/include
)

target_link_directories(generator PRIVATE
    ${LOCAL_PREFIX}/lib
)

target_link_libraries(generator PRIVATE
    cxxopts
    sollya
    mpfr
    gmp
)

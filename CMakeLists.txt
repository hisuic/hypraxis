cmake_minimum_required(VERSION 3.25)
project(hypraxis_overview VERSION 0.2.0 LANGUAGES CXX)

find_package(PkgConfig REQUIRED)
pkg_check_modules(HYPRLAND REQUIRED IMPORTED_TARGET hyprland=0.56.2)
pkg_check_modules(LUA REQUIRED IMPORTED_TARGET lua)

add_library(hypraxis_overview MODULE plugin/main.cpp plugin/Overview.cpp)
set_target_properties(hypraxis_overview PROPERTIES PREFIX "" CXX_STANDARD 23
    CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
target_link_libraries(hypraxis_overview PRIVATE PkgConfig::HYPRLAND PkgConfig::LUA)
target_compile_definitions(hypraxis_overview PRIVATE WLR_USE_UNSTABLE)
target_compile_options(hypraxis_overview PRIVATE -Wall -Wextra -Wpedantic
    -fno-gnu-unique
    "-ffile-prefix-map=${CMAKE_SOURCE_DIR}=."
    "-fmacro-prefix-map=${CMAKE_SOURCE_DIR}=."
    "-fdebug-prefix-map=${CMAKE_BINARY_DIR}=build")

include(GNUInstallDirs)
install(TARGETS hypraxis_overview LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}/hypraxis")

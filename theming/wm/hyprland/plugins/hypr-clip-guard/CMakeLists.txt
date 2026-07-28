cmake_minimum_required(VERSION 3.19)
project(hypr-clip-guard VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(deps REQUIRED IMPORTED_TARGET hyprland hyprlang hyprutils)

add_library(hypr-clip-guard SHARED src/main.cpp)
target_link_libraries(hypr-clip-guard PkgConfig::deps)
set_target_properties(hypr-clip-guard PROPERTIES PREFIX "")
install(TARGETS hypr-clip-guard LIBRARY DESTINATION lib)

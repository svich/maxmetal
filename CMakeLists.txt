cmake_minimum_required(VERSION 3.16)
project(maxmetal VERSION 0.1.0 LANGUAGES C)

option(MAXMETAL_BUILD_CLI "Build the maxmetal command-line tool" ON)
option(MAXMETAL_BUILD_DIFF "Build maxmetal-diff, the GPU differential check (macOS, Metal)" ${APPLE})
if(CMAKE_SOURCE_DIR STREQUAL PROJECT_SOURCE_DIR)
  set(top ON)
endif()
option(MAXMETAL_BUILD_TESTS "Build the tests (ctest)" ${top})

include(GNUInstallDirs)

# libmaxmetal: static by default, -DBUILD_SHARED_LIBS=ON for a shared library
add_library(maxmetal src/translate.c)
add_library(maxmetal::maxmetal ALIAS maxmetal)
set_target_properties(maxmetal PROPERTIES C_STANDARD 11 VERSION ${PROJECT_VERSION} SOVERSION ${PROJECT_VERSION_MAJOR})
target_include_directories(maxmetal PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
                                           $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)
if(NOT MSVC)
  target_link_libraries(maxmetal PRIVATE m)
endif()
install(TARGETS maxmetal EXPORT maxmetalTargets)
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT maxmetalTargets FILE maxmetalConfig.cmake NAMESPACE maxmetal::
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/maxmetal)

if(MAXMETAL_BUILD_CLI)
  add_executable(maxmetal-cli cli/maxmetal.c)
  set_target_properties(maxmetal-cli PROPERTIES OUTPUT_NAME maxmetal C_STANDARD 11)
  target_link_libraries(maxmetal-cli PRIVATE maxmetal)
  install(TARGETS maxmetal-cli)
endif()

if(MAXMETAL_BUILD_DIFF)
  enable_language(OBJC)
  add_executable(maxmetal-diff tools/maxmetal_diff.m)
  target_compile_options(maxmetal-diff PRIVATE -fobjc-arc)
  target_link_libraries(maxmetal-diff PRIVATE "-framework Foundation" "-framework Metal")
endif()

if(MAXMETAL_BUILD_TESTS)
  enable_testing()
  add_executable(test_translate tests/test_translate.c)
  set_target_properties(test_translate PROPERTIES C_STANDARD 11)
  target_link_libraries(test_translate PRIVATE maxmetal)
  # translate: the hand-assembled programs against tests/golden; metal_compile: their MSL through the Metal compiler
  set(out ${CMAKE_CURRENT_BINARY_DIR}/tests-out)
  file(MAKE_DIRECTORY ${out})
  add_test(NAME translate COMMAND test_translate ${CMAKE_CURRENT_SOURCE_DIR}/tests/golden ${out})
  if(APPLE)
    add_test(NAME metal_compile COMMAND ${CMAKE_COMMAND} -DDIR=${out} -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/metal_compile.cmake)
    set_tests_properties(metal_compile PROPERTIES DEPENDS translate)
  endif()
  # corpus: a shader cache (MAXMETAL_CORPUS=<dir>) against tests/corpus-baseline.txt; skipped without one
  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_FOUND AND MAXMETAL_BUILD_CLI)
    add_test(NAME corpus COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/corpus.py
             --maxmetal $<TARGET_FILE:maxmetal-cli> --baseline ${CMAKE_CURRENT_SOURCE_DIR}/tests/corpus-baseline.txt)
    set_tests_properties(corpus PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 3600)
  endif()
endif()

# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(PuttyLib)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(LIBS_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../libs/arm64-v8a)
set(INCLUDE_ROOT_PATH ${LIBS_ROOT_PATH}/../)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include
                    ${INCLUDE_ROOT_PATH}/include
                    ${NATIVERENDER_ROOT_PATH}/../
                    )

target_sources(entry PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/telnetSession.cpp)

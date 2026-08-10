# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(PuttyLib)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(LIBS_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/arm64-v8a)
set(INCLUDE_ROOT_PATH ${LIBS_ROOT_PATH}/../)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include
                    ${INCLUDE_ROOT_PATH}/include
                    )

add_subdirectory(${NATIVERENDER_ROOT_PATH}/ssh)
add_subdirectory(${NATIVERENDER_ROOT_PATH}/telnetSession)
add_subdirectory(${NATIVERENDER_ROOT_PATH}/serialSession)
add_subdirectory(${NATIVERENDER_ROOT_PATH}/SessionManager)
add_subdirectory(${NATIVERENDER_ROOT_PATH}/SessionFactory)

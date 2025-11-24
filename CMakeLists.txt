cmake_minimum_required(VERSION 3.5.0)

project(hailort_examples LANGUAGES CXX)

# Use C++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Find HailoRT
find_package(HailoRT 4.23.0 EXACT REQUIRED)

# Find OpenCV
find_package(OpenCV REQUIRED)

# Find jsoncpp via pkg-config if possible
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(JSONCPP QUIET jsoncpp)
endif()

# If jsoncpp is not found via pkg-config, we will still try to link "jsoncpp"
if(NOT JSONCPP_FOUND)
    message(STATUS "jsoncpp via pkg-config not found, will link against 'jsoncpp' directly")
endif()

# Sources
set(SRC_FILES
    src/inference_driver.cpp
    src/util.cpp
)

add_executable(inference_driver ${SRC_FILES})

# Include directories
target_include_directories(inference_driver
    PRIVATE
        src                       # for util.hpp
        ${OpenCV_INCLUDE_DIRS}
        ${JSONCPP_INCLUDE_DIRS}   # may be empty if not found
)

# Link libraries
target_link_libraries(inference_driver
    PRIVATE
        hailort
        ${OpenCV_LIBS}
)

# Link jsoncpp
if(JSONCPP_FOUND)
    target_link_libraries(inference_driver PRIVATE ${JSONCPP_LIBRARIES})
else()
    target_link_libraries(inference_driver PRIVATE jsoncpp)
endif()
cmake_minimum_required(VERSION 3.5.0)

project(hailort_examples LANGUAGES CXX)

# Use C++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Find HailoRT
set(HAILORT_REQUIRED_VERSION 4.24.0)
find_package(HailoRT ${HAILORT_REQUIRED_VERSION} EXACT REQUIRED)

# Find OpenCV
find_package(OpenCV REQUIRED)

# multi_process uses std::thread for input/output VStreams.
find_package(Threads REQUIRED)

# Find jsoncpp via pkg-config if possible
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(JSONCPP QUIET jsoncpp)
endif()

# If jsoncpp is not found via pkg-config, we will still try to link "jsoncpp"
if(NOT JSONCPP_FOUND)
    message(STATUS "jsoncpp via pkg-config not found, will link against 'jsoncpp' directly")
endif()

# Sources for each executable
set(INFERENCE_DRIVER_SRC
    src/inference_driver.cpp
    src/util.cpp
)

set(MULTI_PROCESS_SRC
    src/multi_process.cpp
    src/util.cpp
)

# Executables
add_executable(inference_driver ${INFERENCE_DRIVER_SRC})
add_executable(multi_process ${MULTI_PROCESS_SRC})

# Include directories
target_include_directories(inference_driver
    PRIVATE
        src                       # for util.hpp
        ${OpenCV_INCLUDE_DIRS}
        ${JSONCPP_INCLUDE_DIRS}   # may be empty if not found
)

target_include_directories(multi_process
    PRIVATE
        src
        ${OpenCV_INCLUDE_DIRS}
        ${JSONCPP_INCLUDE_DIRS}
)

# Link libraries
target_link_libraries(inference_driver
    PRIVATE
        HailoRT::libhailort
        ${OpenCV_LIBS}
)

target_link_libraries(multi_process
    PRIVATE
        HailoRT::libhailort
        ${OpenCV_LIBS}
        Threads::Threads
)


# Link jsoncpp
if(JSONCPP_FOUND)
    target_link_libraries(inference_driver PRIVATE ${JSONCPP_LIBRARIES})
    target_link_libraries(multi_process PRIVATE ${JSONCPP_LIBRARIES})
else()
    target_link_libraries(inference_driver PRIVATE jsoncpp)
    target_link_libraries(multi_process PRIVATE jsoncpp)
endif()

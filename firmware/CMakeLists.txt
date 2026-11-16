cmake_minimum_required(VERSION 3.16)

# Build the application and its declared dependencies.
set(COMPONENTS main)
set(PROJECT_VER "3.2.0")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(spectrulenpor_firmware)

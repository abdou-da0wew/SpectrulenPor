cmake_minimum_required(VERSION 3.16)

# Build the application and its declared dependencies.
# Project author: Malak Adel Sayed Hassan. Main firmware code author: Abdou (عبد الرحمن أيمن محمد).
# Source: https://github.com/abdou-da0wew/SpectrulenPor
set(COMPONENTS main)
set(PROJECT_VER "3.2.0")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(spectrulenpor_firmware)

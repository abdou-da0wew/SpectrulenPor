# SpectruLenPor ESP32-CAM Smart Glasses Firmware
#
# Pure ESP-IDF project (NOT Arduino). Build on hpc2 via SSH:
#   idf.py set-target esp32
#   idf.py build
#   idf.py flash (when you approve)

cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(spectrulenpor_firmware)

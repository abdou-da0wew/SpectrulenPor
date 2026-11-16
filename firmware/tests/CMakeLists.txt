cmake_minimum_required(VERSION 3.16)
project(spectrulenpor_protocol_tests C)

enable_testing()
option(ENABLE_SANITIZERS "Check memory bounds and undefined behavior" ON)
add_executable(protocol_tests
  protocol_tests.c
  ../components/protocol/protocol.c
)
target_include_directories(protocol_tests PRIVATE .. ../components/protocol)
target_compile_features(protocol_tests PRIVATE c_std_11)
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(protocol_tests PRIVATE
    -Wall -Wextra -Werror -Wpedantic -Wconversion -Wshadow
  )
  if(ENABLE_SANITIZERS)
    target_compile_options(protocol_tests PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
    target_link_options(protocol_tests PRIVATE -fsanitize=address,undefined)
  endif()
endif()
foreach(group commands jpeg udp)
  add_test(NAME ${group} COMMAND protocol_tests ${group})
endforeach()

cmake_minimum_required(VERSION 3.20)
project(HydraSession LANGUAGES C OBJC)

if(NOT CMAKE_LIBRARY_OUTPUT_DIRECTORY)
  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../build/lib")
endif()

find_package(WinPR 3 REQUIRED CONFIG)
find_package(FreeRDP 3 REQUIRED CONFIG)
find_package(FreeRDP-Client 3 REQUIRED CONFIG)

add_library(HydraSession SHARED
  hydra_session.c
  hydra_channels.c
  hydra_clipboard.c
)
target_include_directories(HydraSession PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(HydraSession PRIVATE freerdp-client)
set_target_properties(HydraSession PROPERTIES
  OUTPUT_NAME HydraSession
  BUILD_WITH_INSTALL_RPATH TRUE
  INSTALL_NAME_DIR "@rpath"
  MACOSX_RPATH ON
)

cmake_minimum_required(VERSION 3.24)
project(gfx-vcpkg-cache-test LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# MaterialXConfig.cmake does not call find_dependency(X11), so we need to
# find X11 before loading pxr/MaterialX. This is a bug in MaterialX's CMake
# packaging: https://github.com/AcademySoftwareFoundation/MaterialX
if (CMAKE_SYSTEM_NAME STREQUAL "Linux")
  find_package(X11 REQUIRED)
endif()

find_package(pxr CONFIG REQUIRED)

# OpenUSD requires OpenGL
find_package(OpenGL REQUIRED)

# Determine which USD library targets are available
if (TARGET usd_ms OR TARGET usd_m)
  set(REQUIRED_USD_LIBS ${PXR_LIBRARIES})
elseif(TARGET usd)
  set(REQUIRED_USD_LIBS usd sdf tf usdImaging)
else()
  message(FATAL_ERROR "No USD targets found. Something is wrong with USD installation.")
endif()

# Suppress deprecated warnings from pxr headers
foreach(lib ${REQUIRED_USD_LIBS})
  if(TARGET ${lib})
    target_compile_options(${lib} INTERFACE
      "$<$<CXX_COMPILER_ID:GNU>:-Wno-deprecated>")
  endif()
endforeach()

add_executable(testusd src/main.cc)

target_link_libraries(testusd PRIVATE ${REQUIRED_USD_LIBS})

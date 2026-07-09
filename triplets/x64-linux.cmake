set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_CMAKE_SYSTEM_NAME Linux)

# GCC 15 workarounds for vcpkg ports that haven't caught up yet:
# - _GNU_SOURCE: exposes qsort_r and other GNU extensions in glibc headers (e.g. zstd).
# - -include cstdint: GCC 15 removed transitive <cstdint> includes, breaking ports
#   like MaterialX that use uint8_t/uint16_t without including it directly.
#   Only needed for C++; avoid -include stdint.h in C flags as it breaks autotools builds.
set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -D_GNU_SOURCE")
set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -include cstdint")

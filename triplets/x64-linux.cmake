set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_CMAKE_SYSTEM_NAME Linux)

# GCC 15 no longer transitively includes <cstdint> from other standard headers.
# Many vcpkg ports (e.g. MaterialX) rely on this transitive include.
set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -include stdint.h -D_GNU_SOURCE")
set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -include cstdint")

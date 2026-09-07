# LightOffice size-optimisation profile (CMake).
#
# Applies to the desktop-sdk targets, which are the CMake-driven part of the
# tree. Use with: cmake -C .../lightoffice_size_opt.cmake  (or include() it).

set(CMAKE_C_FLAGS_RELEASE   "-Os -ffunction-sections -fdata-sections" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_RELEASE "-Os -ffunction-sections -fdata-sections" CACHE STRING "" FORCE)

foreach(_t EXE SHARED MODULE)
  set(CMAKE_${_t}_LINKER_FLAGS_RELEASE
      "-Wl,--gc-sections -Wl,--as-needed -Wl,-O1 -Wl,-s" CACHE STRING "" FORCE)
endforeach()

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE ON CACHE BOOL "" FORCE)

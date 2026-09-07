# LightOffice size-optimisation profile (qmake).
#
# ONLYOFFICE builds with qmake, not CMake — desktop-apps and core are driven by
# 137 .pro files, and only desktop-sdk carries CMakeLists. The equivalent CMake
# profile lives in lightoffice_size_opt.cmake for those targets.
#
# Included from defaults.pri by scripts/apply_build_flags.sh.

CONFIG(release, debug|release) {
    # -Os over -O2: the editors are dominated by cold code paths, so trading a
    # little throughput for a materially smaller binary is the right call for a
    # "lightweight" edition.
    QMAKE_CFLAGS_RELEASE   -= -O2
    QMAKE_CXXFLAGS_RELEASE -= -O2
    QMAKE_CFLAGS_RELEASE   += -Os
    QMAKE_CXXFLAGS_RELEASE += -Os

    # Emit every function/data item into its own section so the linker can drop
    # the ones nothing references. Useless without --gc-sections below.
    QMAKE_CFLAGS_RELEASE   += -ffunction-sections -fdata-sections
    QMAKE_CXXFLAGS_RELEASE += -ffunction-sections -fdata-sections

    # RTTI and exceptions are kept: the core relies on both, and disabling them
    # here would break the build rather than shrink it.

    QMAKE_LFLAGS_RELEASE += -Wl,--gc-sections
    QMAKE_LFLAGS_RELEASE += -Wl,--as-needed
    QMAKE_LFLAGS_RELEASE += -Wl,-O1

    # Strip at link time. Note this removes the symbols needed to symbolicate a
    # crash report, so keep the unstripped binary from the build directory if
    # you want usable backtraces from the field.
    QMAKE_LFLAGS_RELEASE += -Wl,-s
}

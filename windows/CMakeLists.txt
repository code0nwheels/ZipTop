# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(ziptop LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "ziptop")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# === ZipTop: replace media_kit's bundled libmpv ===
# media_kit_libs_windows_video ships mpv 0.36 (September 2023), whose FFmpeg
# DASH demuxer crashes the process on the backend's live .mpd manifests.
# This pinned upstream build (mpv 0.42) plays them. The archive is kept in
# windows/third_party/ (git-ignored) and downloaded only if it is missing.
# Installed after the plugin libraries so it overwrites their libmpv-2.dll.
# lib/player/mpv_player.dart refuses DASH when an older libmpv is loaded.
set(ZIPTOP_LIBMPV_TAG "20261110")
set(ZIPTOP_LIBMPV_NAME "mpv-dev-x86_64-20261110-git-a61f6c3abd.7z")
set(ZIPTOP_LIBMPV_URL "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/${ZIPTOP_LIBMPV_TAG}/${ZIPTOP_LIBMPV_NAME}")
set(ZIPTOP_LIBMPV_SHA256 "f07b97a72f2394a7798d6e1d36d952bbfd63577e25cef051f716751ea5dc9688")
set(ZIPTOP_LIBMPV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libmpv")
set(ZIPTOP_LIBMPV_ARCHIVE "${ZIPTOP_LIBMPV_DIR}/${ZIPTOP_LIBMPV_NAME}")
set(ZIPTOP_LIBMPV_OUT "${ZIPTOP_LIBMPV_DIR}/${ZIPTOP_LIBMPV_TAG}")
set(ZIPTOP_LIBMPV_DLL "${ZIPTOP_LIBMPV_OUT}/libmpv-2.dll")

if(NOT EXISTS "${ZIPTOP_LIBMPV_DLL}")
  if(NOT EXISTS "${ZIPTOP_LIBMPV_ARCHIVE}")
    message(STATUS "Downloading ${ZIPTOP_LIBMPV_NAME}")
    file(DOWNLOAD "${ZIPTOP_LIBMPV_URL}" "${ZIPTOP_LIBMPV_ARCHIVE}"
      EXPECTED_HASH SHA256=${ZIPTOP_LIBMPV_SHA256}
      SHOW_PROGRESS)
  else()
    file(SHA256 "${ZIPTOP_LIBMPV_ARCHIVE}" ZIPTOP_LIBMPV_ACTUAL)
    if(NOT ZIPTOP_LIBMPV_ACTUAL STREQUAL ZIPTOP_LIBMPV_SHA256)
      message(FATAL_ERROR "${ZIPTOP_LIBMPV_ARCHIVE} does not match the pinned SHA-256. Delete it to download again.")
    endif()
  endif()
  file(MAKE_DIRECTORY "${ZIPTOP_LIBMPV_OUT}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xf "${ZIPTOP_LIBMPV_ARCHIVE}" libmpv-2.dll
    WORKING_DIRECTORY "${ZIPTOP_LIBMPV_OUT}"
    RESULT_VARIABLE ZIPTOP_LIBMPV_EXTRACT)
  if(NOT ZIPTOP_LIBMPV_EXTRACT EQUAL 0 OR NOT EXISTS "${ZIPTOP_LIBMPV_DLL}")
    message(FATAL_ERROR "Could not extract libmpv-2.dll from ${ZIPTOP_LIBMPV_ARCHIVE}")
  endif()
endif()

install(FILES "${ZIPTOP_LIBMPV_DLL}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

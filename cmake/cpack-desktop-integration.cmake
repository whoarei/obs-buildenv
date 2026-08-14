# Keep the private OBS runtime under /usr/local/ans while installing only the
# desktop-shell integration in the standard XDG data directory.

if(NOT DEFINED CPACK_TEMPORARY_DIRECTORY OR CPACK_TEMPORARY_DIRECTORY STREQUAL "")
  message(FATAL_ERROR "CPACK_TEMPORARY_DIRECTORY is unavailable")
endif()

set(_package_root "${CPACK_TEMPORARY_DIRECTORY}")

function(_move_desktop_file source_relative destination_relative)
  set(source "${_package_root}/${source_relative}")
  set(destination "${_package_root}/${destination_relative}")

  if(NOT EXISTS "${source}")
    message(FATAL_ERROR "Required OBS desktop integration file is missing: ${source_relative}")
  endif()

  get_filename_component(destination_directory "${destination}" DIRECTORY)
  file(MAKE_DIRECTORY "${destination_directory}")
  file(RENAME "${source}" "${destination}")
endfunction()

_move_desktop_file(
  "usr/local/ans/share/applications/com.obsproject.Studio.desktop"
  "usr/share/applications/com.obsproject.Studio.desktop"
)
_move_desktop_file(
  "usr/local/ans/share/metainfo/com.obsproject.Studio.metainfo.xml"
  "usr/share/metainfo/com.obsproject.Studio.metainfo.xml"
)
_move_desktop_file(
  "usr/local/ans/share/icons/hicolor/128x128/apps/com.obsproject.Studio.png"
  "usr/share/icons/hicolor/128x128/apps/com.obsproject.Studio.png"
)
_move_desktop_file(
  "usr/local/ans/share/icons/hicolor/256x256/apps/com.obsproject.Studio.png"
  "usr/share/icons/hicolor/256x256/apps/com.obsproject.Studio.png"
)
_move_desktop_file(
  "usr/local/ans/share/icons/hicolor/512x512/apps/com.obsproject.Studio.png"
  "usr/share/icons/hicolor/512x512/apps/com.obsproject.Studio.png"
)
_move_desktop_file(
  "usr/local/ans/share/icons/hicolor/scalable/apps/com.obsproject.Studio.svg"
  "usr/share/icons/hicolor/scalable/apps/com.obsproject.Studio.svg"
)

set(_desktop_file "${_package_root}/usr/share/applications/com.obsproject.Studio.desktop")
file(READ "${_desktop_file}" _desktop_contents)
string(REGEX MATCHALL "Exec=obs" _exec_matches "${_desktop_contents}")
list(LENGTH _exec_matches _exec_match_count)
if(NOT _exec_match_count EQUAL 1)
  message(FATAL_ERROR "Expected exactly one 'Exec=obs' entry, found ${_exec_match_count}")
endif()

string(REPLACE
  "Exec=obs"
  "Exec=/usr/bin/env PAN_MESA_DEBUG=gl3 /usr/local/ans/bin/mesa25-run /usr/local/ans/bin/obs"
  _desktop_contents
  "${_desktop_contents}"
)
file(WRITE "${_desktop_file}" "${_desktop_contents}")

message(STATUS "Installed OBS desktop integration with Mesa 25 and Panfrost GL 3.3")

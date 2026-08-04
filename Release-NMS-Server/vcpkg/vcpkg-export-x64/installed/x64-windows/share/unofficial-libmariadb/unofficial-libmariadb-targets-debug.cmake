#----------------------------------------------------------------
# Generated CMake target import file for configuration "Debug".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "mariadbclient" for configuration "Debug"
set_property(TARGET mariadbclient APPEND PROPERTY IMPORTED_CONFIGURATIONS DEBUG)
set_target_properties(mariadbclient PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_DEBUG "C"
  IMPORTED_LOCATION_DEBUG "${_IMPORT_PREFIX}/debug/lib/mariadbclient.lib"
  )

list(APPEND _IMPORT_CHECK_TARGETS mariadbclient )
list(APPEND _IMPORT_CHECK_FILES_FOR_mariadbclient "${_IMPORT_PREFIX}/debug/lib/mariadbclient.lib" )

# Import target "libmariadb" for configuration "Debug"
set_property(TARGET libmariadb APPEND PROPERTY IMPORTED_CONFIGURATIONS DEBUG)
set_target_properties(libmariadb PROPERTIES
  IMPORTED_IMPLIB_DEBUG "${_IMPORT_PREFIX}/debug/lib/libmariadb.lib"
  IMPORTED_LOCATION_DEBUG "${_IMPORT_PREFIX}/debug/bin/libmariadb.dll"
  )

list(APPEND _IMPORT_CHECK_TARGETS libmariadb )
list(APPEND _IMPORT_CHECK_FILES_FOR_libmariadb "${_IMPORT_PREFIX}/debug/lib/libmariadb.lib" "${_IMPORT_PREFIX}/debug/bin/libmariadb.dll" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)

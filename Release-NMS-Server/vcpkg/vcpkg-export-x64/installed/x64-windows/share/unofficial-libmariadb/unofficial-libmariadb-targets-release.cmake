#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "mariadbclient" for configuration "Release"
set_property(TARGET mariadbclient APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(mariadbclient PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "C"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/mariadbclient.lib"
  )

list(APPEND _IMPORT_CHECK_TARGETS mariadbclient )
list(APPEND _IMPORT_CHECK_FILES_FOR_mariadbclient "${_IMPORT_PREFIX}/lib/mariadbclient.lib" )

# Import target "libmariadb" for configuration "Release"
set_property(TARGET libmariadb APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(libmariadb PROPERTIES
  IMPORTED_IMPLIB_RELEASE "${_IMPORT_PREFIX}/lib/libmariadb.lib"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/bin/libmariadb.dll"
  )

list(APPEND _IMPORT_CHECK_TARGETS libmariadb )
list(APPEND _IMPORT_CHECK_FILES_FOR_libmariadb "${_IMPORT_PREFIX}/lib/libmariadb.lib" "${_IMPORT_PREFIX}/bin/libmariadb.dll" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)

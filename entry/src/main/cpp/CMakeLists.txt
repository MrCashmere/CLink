cmake_minimum_required(VERSION 3.4.1)
project(archive_zip_only)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

file(GLOB LIBARCHIVE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/libarchive/*.c")
list(FILTER LIBARCHIVE_SOURCES EXCLUDE REGEX ".*/archive_read_support_filter_(bzip2|compress|grzip|lrzip|lz4|lzop|rpm|xz|zstd)\\.c$")
list(FILTER LIBARCHIVE_SOURCES EXCLUDE REGEX ".*/archive_write_.*")
list(FILTER LIBARCHIVE_SOURCES EXCLUDE REGEX ".*/archive_read_disk_.*")
list(FILTER LIBARCHIVE_SOURCES EXCLUDE REGEX ".*/archive_read_extract.*")
list(FILTER LIBARCHIVE_SOURCES EXCLUDE REGEX ".*/archive_read_support_filter_(all|by_code|program)\\.c$")
list(FILTER LIBARCHIVE_SOURCES EXCLUDE REGEX ".*/archive_read_(append_filter|support_format_all|support_format_by_code)\\.c$")
list(FILTER LIBARCHIVE_SOURCES EXCLUDE REGEX ".*/archive_match\\.c$")
list(FILTER LIBARCHIVE_SOURCES EXCLUDE REGEX ".*/archive_read_support_format_(7zip|ar|cab|cpio|iso9660|lha|mtree|rar|rar5|raw|tar|warc|xar)\\.c$")
add_library(archive_zip_only SHARED ${LIBARCHIVE_SOURCES} archive_zip_only.c)
target_include_directories(archive_zip_only PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/libarchive)
target_compile_definitions(archive_zip_only PRIVATE PLATFORM_CONFIG_H=\"config_ohos.h\")
target_link_libraries(archive_zip_only PUBLIC libace_napi.z.so z)

# --- LocalSend TLS transport (mbedTLS, vendored) ---
# mbedTLS v3.6.0 source is vendored under entry/src/main/cpp/mbedtls/ (library/*.c + include/).
# It uses its default mbedtls_config.h (TLS 1.2 client+server, RSA/ECP, X.509, AES/GCM,
# SHA-256, entropy, ctr_drbg) and builds as a single static lib from library/*.c.
# This module owns the TCP socket end-to-end (POSIX connect/listen/accept) and carries the
# mbedTLS record layer over it, so there is no @ohos.net.socket event loop competing with
# mbedTLS on the same fd (which is why handing over getSocketFd stalled the handshake).
# See docs/LOCALSEND_TLS.md.
file(GLOB MBEDTLS_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/mbedtls/library/*.c")
add_library(mbedtls STATIC ${MBEDTLS_SOURCES})
# Link the static mbedtls into the shared tls_transport.so -> must be built as PIC.
set_target_properties(mbedtls PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(mbedtls
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/mbedtls/include
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/mbedtls/library)

add_library(tls_transport SHARED tls_transport.cpp)
# libhilog_ndk.z.so: OH_LOG_Print diagnostic logging for the native TLS handshake.
target_link_libraries(tls_transport PUBLIC libace_napi.z.so libhilog_ndk.z.so mbedtls pthread)

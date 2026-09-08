#include "archive_platform.h"
#include "archive.h"

/* The mobile build intentionally ships only ZIP support.  The generic
 * libarchive dispatcher references every optional format, so provide a
 * narrow dispatcher that keeps the linker free of unused format backends. */
int archive_read_support_format_by_code(struct archive *a, int code)
{
    if ((code & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_ZIP) {
        return archive_read_support_format_zip(a);
    }
    return ARCHIVE_WARN;
}

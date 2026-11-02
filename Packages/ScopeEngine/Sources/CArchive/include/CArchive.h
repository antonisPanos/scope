// The part of libarchive's public API that Scope uses.
//
// macOS ships libarchive (it is what bsdtar and ditto use) and the SDK
// includes its link stub, but not its headers, so the declarations are
// repeated here from libarchive 3's archive.h and archive_entry.h. They are
// stable, documented API: https://github.com/libarchive/libarchive/wiki
#ifndef SCOPE_CARCHIVE_H
#define SCOPE_CARCHIVE_H

#include <stdint.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_RETRY (-10)
#define ARCHIVE_WARN (-20)
#define ARCHIVE_FAILED (-25)
#define ARCHIVE_FATAL (-30)

// Entry types (archive_entry.h's AE_IF* values), as constants Swift can see.
static const unsigned int AE_IFMT = 0170000;
static const unsigned int AE_IFREG = 0100000;
static const unsigned int AE_IFLNK = 0120000;
static const unsigned int AE_IFDIR = 0040000;

// Reading
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_set_option(struct archive *, const char *, const char *, const char *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_open_fd(struct archive *, int fd, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buffer, size_t size);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
int archive_format(struct archive *);
int archive_filter_count(struct archive *);
int archive_filter_code(struct archive *, int);

// Writing
struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_set_format_7zip(struct archive *);
int archive_write_add_filter_gzip(struct archive *);
typedef int scope_archive_open_callback(struct archive *, void *);
typedef ssize_t scope_archive_write_callback(struct archive *, void *, const void *, size_t);
typedef int scope_archive_close_callback(struct archive *, void *);
typedef int scope_archive_free_callback(struct archive *, void *);
int archive_write_open2(struct archive *, void *, scope_archive_open_callback *,
    scope_archive_write_callback *, scope_archive_close_callback *, scope_archive_free_callback *);
int archive_write_set_bytes_per_block(struct archive *, int);
int archive_write_set_bytes_in_last_block(struct archive *, int);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_fail(struct archive *);
int archive_write_free(struct archive *);

// Errors
const char *archive_error_string(struct archive *);

// Entries
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
const void *archive_entry_mac_metadata(struct archive_entry *, size_t *);
int archive_entry_xattr_reset(struct archive_entry *);
int archive_entry_xattr_next(struct archive_entry *, const char **, const void **, size_t *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, mode_t);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_mtime(struct archive_entry *, time_t, long);
void archive_entry_set_symlink(struct archive_entry *, const char *);

#endif

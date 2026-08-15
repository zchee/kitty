/*
 * launcher.h
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef struct CLIOptions {
    const char *session, *instance_group;
    bool wait_for_single_instance_window_close;
    int open_url_count;
    char **open_urls;
} CLIOptions;


typedef struct argv_array {
    char **argv, *buf;
    size_t capacity, count, pos;
    bool needs_free;
} argv_array;


// The macOS SDK's os_log_error() macro expands to code annotated with
// __attribute__((stack_protector_ignore)), an attribute that Homebrew/swiftlang
// builds of clang do not recognize. Under -Werror that emits a fatal
// -Wunknown-attributes error, so wrap calls to silence only that warning. The
// guard becomes a no-op once the compiler learns the attribute.
#ifdef __APPLE__
#define OS_LOG_ERROR(...) \
    _Pragma("clang diagnostic push") \
    _Pragma("clang diagnostic ignored \"-Wunknown-attributes\"") \
    os_log_error(__VA_ARGS__); \
    _Pragma("clang diagnostic pop")
#endif

void single_instance_main(int argc, char *argv[], const CLIOptions *opts);
bool get_argv_from(const char *filename, const char *argv0, argv_array *ans);
bool append_arg_to_argv_array(argv_array *a, const char *arg);
void free_argv_array(argv_array *a);

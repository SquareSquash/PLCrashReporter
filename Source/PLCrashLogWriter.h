/*
 * Author: Landon Fuller <landonf@plausiblelabs.com>
 *
 * Copyright (c) 2008-2013 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import <TargetConditionals.h>
#import <Foundation/Foundation.h>

#import "PLCrashAsync.h"
#import "PLCrashAsyncImageList.h"

/**
 * @internal
 * @defgroup plcrash_log_writer Crash Log Writer
 * @ingroup plcrash_internal
 *
 * Implements an async-safe, zero allocation crash log writer C API, intended
 * to be called from the crash log signal handler.
 *
 * @{
 */

/**
 * @internal
 *
 * @a NSException @a userInfo dictionary entry.
 */
typedef struct user_info_t {
    /** Key name. */
    char *key;
    /** For @a NSCoding-complaint objects, the output of @ NSKeyedArchiver. For
        other objects, the result of calling @a description. */
    char *serialized;
    /** If true, serialized contains @a NSKeyedArchiver output. */
    BOOL archive;
} user_info_t;

/**
 * @internal
 *
 * Crash log writer context.
 */
typedef struct plcrash_log_writer {
    /** Report data */
    struct {
        /** If true, the report should be marked as a 'generated' user-requested report, rather than as a true crash
         * report */
        bool user_requested;
    } report_info;

    /** System data */
    struct {
        /** The host OS version. */
        char *version;

        /** The host OS build number. This may be NULL. */
        char *build;
    } system_info;

    /* Machine data */
    struct {
        /** The host model (may be NULL). */
        char *model;

        /** The host CPU type. */
        uint64_t cpu_type;

        /** The host CPU subtype. */
        uint64_t cpu_subtype;
        
        /** The total number of physical cores */
        uint32_t processor_count;
        
        /** The total number of logical cores */
        uint32_t logical_processor_count;
    } machine_info;

    /** Application data */
    struct {
        /** Application identifier */
        char *app_identifier;

        /** Application version */
        char *app_version;
    } application_info;
    
    /** Process data */
    struct {
        /** Process name (may be null) */
        char *process_name;
        
        /** Process ID */
        pid_t process_id;
        
        /** Process path (may be null) */
        char *process_path;
        
        /** Parent process name (may be null) */
        char *parent_process_name;
        
        /** Parent process ID */
        pid_t parent_process_id;
        
        /** If false, the reporting process is being run under process emulation (such as Rosetta). */
        bool native;
    } process_info;

    /** Uncaught exception (if any) */
    struct {
        /** Flag specifying wether an uncaught exception is available. */
        bool has_exception;

        /** Exception name (may be null) */
        char *name;

        /** Exception reason (may be null) */
        char *reason;

        /** The original exception call stack (may be null) */
        void **callstack;
        
        /** Call stack frame count, or 0 if the call stack is unavailable */
        size_t callstack_count;

        /** Fields for each key/value pair in the @a userInfo dictionary. */
        user_info_t *user_info;

        /** Number of @a userInfo dictionary pairs. */
        size_t user_info_size;
    } uncaught_exception;
} plcrash_log_writer_t;


plcrash_error_t plcrash_log_writer_init (plcrash_log_writer_t *writer,
                                         NSString *app_identifier,
                                         NSString *app_version,
                                         BOOL user_requested);
void plcrash_log_writer_set_exception (plcrash_log_writer_t *writer, NSException *exception);

/**
 * Write a crash log, fetching the thread state from the current thread.
 *
 * @internal
 * @note This is implemented with an assembly trampoline that fetches the current thread state. Solutions such
 * as getcontext() are not viable here, as returning from getcontext() mutates the state of the stack that
 * we will then walk.
 */
plcrash_error_t plcrash_log_writer_write_curthread (plcrash_log_writer_t *writer,
                                                    plcrash_async_image_list_t *image_list,
                                                    plcrash_async_file_t *file, 
                                                    siginfo_t *siginfo);

plcrash_error_t plcrash_log_writer_write (plcrash_log_writer_t *writer,
                                          thread_t crashed_thread,
                                          plcrash_async_image_list_t *image_list,
                                          plcrash_async_file_t *file, 
                                          siginfo_t *siginfo,
                                          ucontext_t *current_context);

plcrash_error_t plcrash_log_writer_close (plcrash_log_writer_t *writer);
void plcrash_log_writer_free (plcrash_log_writer_t *writer);

/**
 * @} plcrash_log_writer
 */

/*
 * Author: Landon Fuller <landonf@plausiblelabs.com>
 *
 * Copyright (c) 2008-2009 Plausible Labs Cooperative, Inc.
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

#import "PLCrashReporter.h"
#import "CrashReporter.h"
#import "PLCrashSignalHandler.h"

#import "PLCrashAsync.h"
#import "PLCrashLogWriter.h"
#import "PLCrashFrameWalker.h"

#import "PLCrashReporterNSError.h"

#if TARGET_OS_MAC && !TARGET_IPHONE_SIMULATOR && !TARGET_OS_IPHONE
#import <ExceptionHandling/ExceptionHandling.h>
#endif

#import <fcntl.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#define NSDEBUG(msg, args...) {\
    NSLog(@"[PLCrashReporter] " msg, ## args); \
}

/** @internal
 * CrashReporter cache directory name. */
static NSString *PLCRASH_CACHE_DIR = @"com.plausiblelabs.crashreporter.data";

/** @internal
 * Crash Report file name. */
static NSString *PLCRASH_LIVE_CRASHREPORT = @"live_report.plcrash";

/** @internal
 * Directory containing crash reports queued for sending. */
static NSString *PLCRASH_QUEUED_DIR = @"queued_reports";

/** @internal
 * Maximum number of bytes that will be written to the crash report.
 * Used as a safety measure in case of implementation malfunction.
 *
 * We provide for a generous 64k here. Most crash reports
 * are approximately 7k.
 */
#define MAX_REPORT_BYTES (64 * 1024)

/**
 * @internal
 * Crash reporter singleton.
 */
static PLCrashReporter *sharedReporter = nil;


/**
 * @internal
 * Signal handler context
 */
typedef struct signal_handler_ctx {
    /** PLCrashLogWriter instance */
    plcrash_log_writer_t writer;

    /** Path to the output file */
    const char *path;
} plcrashreporter_handler_ctx_t;

/**
 * @internal
 *
 * Shared dyld image list.
 */
static plcrash_async_image_list_t shared_image_list;


/**
 * @internal
 * 
 * Signal handler context (singleton)
 */
static plcrashreporter_handler_ctx_t signal_handler_context;


/**
 * @internal
 * 
 * The optional user-supplied callbacks invoked after the crash report has been written.
 */
static PLCrashReporterCallbacks crashCallbacks = {
    .version = 0,
    .context = NULL,
    .handleSignal = NULL
};

/**
 * @internal
 *
 * Signal handler callback.
 */
static void signal_handler_callback (int signal, siginfo_t *info, ucontext_t *uap, void *context) {
    plcrashreporter_handler_ctx_t *sigctx = context;
    plcrash_async_file_t file;

    /* Open the output file */
    int fd = open(sigctx->path, O_RDWR|O_CREAT|O_TRUNC, 0644);
    if (fd < 0) {
        PLCF_DEBUG("Could not open the crashlog output file: %s", strerror(errno));
        return;
    }

    /* Initialize the output context */
    plcrash_async_file_init(&file, fd, MAX_REPORT_BYTES);

    /* Write the crash log using the already-initialized writer */
    plcrash_log_writer_write(&sigctx->writer, mach_thread_self(), &shared_image_list, &file, info, uap);
    plcrash_log_writer_close(&sigctx->writer);

    /* Finished */
    plcrash_async_file_flush(&file);
    plcrash_async_file_close(&file);

    /* Call any post-crash callback */
    if (crashCallbacks.handleSignal != NULL)
        crashCallbacks.handleSignal(info, uap, crashCallbacks.context);
}

/**
 * @internal
 * dyld image add notification callback.
 */
static void image_add_callback (const struct mach_header *mh, intptr_t vmaddr_slide) {
    Dl_info info;
    
    /* Look up the image info */
    if (dladdr(mh, &info) == 0) {
        NSLog(@"%s: dladdr(%p, ...) failed", __FUNCTION__, mh);
        return;
    }

    /* Register the image */
    plcrash_nasync_image_list_append(&shared_image_list, (pl_vm_address_t) mh, vmaddr_slide, info.dli_fname);
}

/**
 * @internal
 * dyld image remove notification callback.
 */
static void image_remove_callback (const struct mach_header *mh, intptr_t vmaddr_slide) {
    plcrash_nasync_image_list_remove(&shared_image_list, (uintptr_t) mh);
}


/**
 * @internal
 *
 * Uncaught exception handler. Sets the plcrash_log_writer_t's uncaught exception
 * field, and then triggers a SIGTRAP (synchronous exception) to cause a normal
 * exception dump.
 *
 * XXX: It is possible that another crash may occur between setting the uncaught 
 * exception field, and triggering the signal handler.
 */
static void uncaught_exception_handler (NSException *exception) {
    /* Set the uncaught exception */
    plcrash_log_writer_set_exception(&signal_handler_context.writer, exception);

    /* Synchronously trigger the crash handler */
    abort();
}


@interface PLCrashReporter (PrivateMethods)

- (id) initWithBundle: (NSBundle *) bundle;
- (id) initWithApplicationIdentifier: (NSString *) applicationIdentifier appVersion: (NSString *) applicationVersion;

- (BOOL) populateCrashReportDirectoryAndReturnError: (NSError **) outError;
- (NSString *) crashReportDirectory;
- (NSString *) queuedCrashReportDirectory;
- (NSString *) crashReportPath;

@end


/**
 * Shared application crash reporter.
 */
@implementation PLCrashReporter

+ (void) initialize {
    if (![[self class] isEqual: [PLCrashReporter class]])
        return;

    /* Enable dyld image monitoring */
    plcrash_nasync_image_list_init(&shared_image_list, mach_task_self());
    _dyld_register_func_for_add_image(image_add_callback);
    _dyld_register_func_for_remove_image(image_remove_callback);
}

/**
 * Return the application's crash reporter instance.
 */
+ (PLCrashReporter *) sharedReporter {
    if (sharedReporter == nil)
        sharedReporter = [[PLCrashReporter alloc] initWithBundle: [NSBundle mainBundle]];

    return sharedReporter;
}


/**
 * Returns YES if the application has previously crashed and
 * an pending crash report is available.
 */
- (BOOL) hasPendingCrashReport {
    /* Check for a live crash report file */
    return [[NSFileManager defaultManager] fileExistsAtPath: [self crashReportPath]];
}


/**
 * If an application has a pending crash report, this method returns the crash
 * report data.
 *
 * You may use this to submit the report to your own HTTP server, over e-mail, or even parse and
 * introspect the report locally using the PLCrashReport API.
 *
 * @return Returns nil if the crash report data could not be loaded.
 */
- (NSData *) loadPendingCrashReportData {
    return [self loadPendingCrashReportDataAndReturnError: NULL];
}


/**
 * If an application has a pending crash report, this method returns the crash
 * report data.
 *
 * You may use this to submit the report to your own HTTP server, over e-mail, or even parse and
 * introspect the report locally using the PLCrashReport API.
 
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error object indicating why the pending crash report could not be
 * loaded. If no error occurs, this parameter will be left unmodified. You may specify
 * nil for this parameter, and no error information will be provided.
 *
 * @return Returns nil if the crash report data could not be loaded.
 */
- (NSData *) loadPendingCrashReportDataAndReturnError: (NSError **) outError {
    /* Load the (memory mapped) data */
    return [NSData dataWithContentsOfFile: [self crashReportPath] options: NSMappedRead error: outError];
}


/**
 * Purge a pending crash report.
 *
 * @return Returns YES on success, or NO on error.
 */
- (BOOL) purgePendingCrashReport {
    return [self purgePendingCrashReportAndReturnError: NULL];
}


/**
 * Purge a pending crash report.
 *
 * @return Returns YES on success, or NO on error.
 */
- (BOOL) purgePendingCrashReportAndReturnError: (NSError **) outError {
    return [[NSFileManager defaultManager] removeItemAtPath: [self crashReportPath] error: outError];
}


/**
 * Enable the crash reporter. Once called, all application crashes will
 * result in a crash report being written prior to application exit.
 *
 * @param handling Determines what kinds of @a NSException instances will be
 * handled by the crash reporter.
 *
 * @return Returns YES on success, or NO if the crash reporter could
 * not be enabled.
 */
- (BOOL) enableCrashReporterWithExceptionHandling: (PLExceptionHandling)handling {
    return [self enableCrashReporterWithExceptionHandling:handling andReturnError:nil];
}



/**
 * Enable the crash reporter. Once called, all application crashes will
 * result in a crash report being written prior to application exit.
 *
 * This method must only be invoked once. Further invocations will throw
 * a PLCrashReporterException.
 *
 * @param handling Determines what kinds of @a NSException instances will be
 * handled by the crash reporter.
 *
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error object indicating why the Crash Reporter could not be enabled.
 * If no error occurs, this parameter will be left unmodified. You may specify nil for this
 * parameter, and no error information will be provided.
 *
 * @return Returns YES on success, or NO if the crash reporter could
 * not be enabled.
 */
- (BOOL) enableCrashReporterWithExceptionHandling: (PLExceptionHandling)handling andReturnError: (NSError **) outError {
    /* Check for programmer error */
    if (_enabled)
        [NSException raise: PLCrashReporterException format: @"The crash reporter has alread been enabled"];

    /* Create the directory tree */
    if (![self populateCrashReportDirectoryAndReturnError: outError])
        return NO;

    /* Set up the signal handler context */
    signal_handler_context.path = strdup([[self crashReportPath] UTF8String]); // NOTE: would leak if this were not a singleton struct
    assert(_applicationIdentifier != nil);
    assert(_applicationVersion != nil);
    plcrash_log_writer_init(&signal_handler_context.writer, _applicationIdentifier, _applicationVersion, false);

    /* Enable the signal handler */
    if (![[PLCrashSignalHandler sharedHandler] registerHandlerWithCallback: &signal_handler_callback context: &signal_handler_context error: outError])
        return NO;

    /* Set the uncaught exception handler */
    if (handling == PLExceptionHandlingUncaughtOnly)
        NSSetUncaughtExceptionHandler(&uncaught_exception_handler);
    else if (handling == PLExceptionHandlingAll) {
#if TARGET_OS_MAC && !TARGET_IPHONE_SIMULATOR && !TARGET_OS_IPHONE
        [[NSExceptionHandler defaultExceptionHandler] setExceptionHandlingMask:
         [[NSExceptionHandler defaultExceptionHandler] exceptionHandlingMask] |
         NSHandleUncaughtExceptionMask |
         NSHandleUncaughtSystemExceptionMask |
         NSHandleUncaughtRuntimeErrorMask |
         NSHandleTopLevelExceptionMask | NSHandleOtherExceptionMask];
        [[NSExceptionHandler defaultExceptionHandler] setDelegate:self];
#else
        [NSException raise:PLCrashReporterException format:@"Can only use PLExceptionHandlingAll with OS X builds."];
#endif
    }

    /* Success */
    _enabled = YES;
    return YES;
}

/**
 * Generate a live crash report for a given @a thread, without triggering an actual crash condition.
 * This may be used to log current process state without actually crashing. The crash report data will be
 * returned on success.
 *
 * @param thread The thread which will be marked as the failing thread in the generated report.
 *
 * @return Returns nil if the crash report data could not be generated.
 *
 * @sa PLCrashReporter::generateLiveReportWithMachThread:error:
 */
- (NSData *) generateLiveReportWithThread: (thread_t) thread {
    return [self generateLiveReportWithThread: thread error: NULL];
}


/**
 * Generate a live crash report for a given @a thread, without triggering an actual crash condition.
 * This may be used to log current process state without actually crashing. The crash report data will be
 * returned on success.
 *
 * @param thread The thread which will be marked as the failing thread in the generated report.
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error object indicating why the crash report could not be generated or loaded. If no
 * error occurs, this parameter will be left unmodified. You may specify nil for this parameter, and no
 * error information will be provided.
 *
 * @return Returns nil if the crash report data could not be loaded.
 *
 */
- (NSData *) generateLiveReportWithThread: (thread_t) thread error: (NSError **) outError {
    plcrash_log_writer_t writer;
    plcrash_async_file_t file;
    
    /* Open the output file */
    NSString *templateStr = [NSTemporaryDirectory() stringByAppendingPathComponent: @"live_crash_report.XXXXXX"];
    char *path = strdup([templateStr fileSystemRepresentation]);
    
    int fd = mkstemp(path);
    if (fd < 0) {
        plcrash_populate_posix_error(outError, errno, NSLocalizedString(@"Failed to create temporary path", @"Error opening temporary output path"));
        free(path);

        return nil;
    }

    /* Initialize the output context */
    plcrash_log_writer_init(&writer, _applicationIdentifier, _applicationVersion, true);
    plcrash_async_file_init(&file, fd, MAX_REPORT_BYTES);
    
    /* Mock up a SIGTRAP-based siginfo_t */
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    info.si_signo = SIGTRAP;
    info.si_code = TRAP_TRACE;
    info.si_addr = __builtin_return_address(0);
    
    /* Write the crash log using the already-initialized writer */
    if (thread == mach_thread_self()) {
        plcrash_log_writer_write_curthread(&writer, &shared_image_list, &file, &info);
    } else {
        plcrash_log_writer_write(&writer, thread, &shared_image_list, &file, &info, NULL);
    }
    plcrash_log_writer_close(&writer);

    /* Finished -- clean up. */
    plcrash_async_file_flush(&file);
    plcrash_async_file_close(&file);
    
    plcrash_log_writer_free(&writer);
    
    NSData *data = [NSData dataWithContentsOfFile: [NSString stringWithUTF8String: path]];
    if (data == nil) {
        /* This should only happen if our data is deleted out from under us */
        plcrash_populate_error(outError, PLCrashReporterErrorUnknown, NSLocalizedString(@"Unable to open live crash report for reading", nil), nil);
        free(path);
        return nil;
    }
    
    if (unlink(path) != 0) {
        /* This shouldn't fail, but if it does, there's no use in returning nil */
        NSLog(@"Failure occured deleting live crash report: %s", strerror(errno));
    }

    free(path);
    return data;
}


/**
 * Generate a live crash report, without triggering an actual crash condition. This may be used to log
 * current process state without actually crashing. The crash report data will be returned on
 * success.
 * 
 * @return Returns nil if the crash report data could not be loaded.
 */
- (NSData *) generateLiveReport {
    return [self generateLiveReportAndReturnError: NULL];
}


/**
 * Generate a live crash report for the current thread, without triggering an actual crash condition.
 * This may be used to log current process state without actually crashing. The crash report data will be
 * returned on success.
 *
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error object indicating why the pending crash report could not be
 * generated or loaded. If no error occurs, this parameter will be left unmodified. You may specify
 * nil for this parameter, and no error information will be provided.
 * 
 * @return Returns nil if the crash report data could not be loaded.
 */
- (NSData *) generateLiveReportAndReturnError: (NSError **) outError {
    return [self generateLiveReportWithThread: mach_thread_self() error: outError];
}


/**
 * Set the callbacks that will be executed by the receiver after a crash has occured and been recorded by PLCrashReporter.
 *
 * @param callbacks A pointer to an initialized PLCrashReporterCallbacks structure.
 *
 * @note This method must be called prior to PLCrashReporter::enableCrashReporterWithExceptionHandling: or
 * PLCrashReporter::enableCrashReporterWithExceptionHandling:andReturnError:
 *
 * @sa @ref async_safety
 */
- (void) setCrashCallbacks: (PLCrashReporterCallbacks *) callbacks {
    /* Check for programmer error; this should not be called after the signal handler is enabled as to ensure that
     * the signal handler can never fire with a partially initialized callback structure. */
    if (_enabled)
        [NSException raise: PLCrashReporterException format: @"The crash reporter has alread been enabled"];

    assert(callbacks->version == 0);

    /* Re-initialize our internal callback structure */
    crashCallbacks.version = 0;

    /* Re-configure the saved callbacks */
    crashCallbacks.context = callbacks->context;
    crashCallbacks.handleSignal = callbacks->handleSignal;
}


@end

/**
 * @internal
 *
 * Private Methods
 */
@implementation PLCrashReporter (PrivateMethods)

/**
 * @internal
 *
 * This is the designated initializer, but it is not intended
 * to be called externally.
 */
- (id) initWithApplicationIdentifier: (NSString *) applicationIdentifier appVersion: (NSString *) applicationVersion {
    /* Only allow one instance to be created, no matter what */
    if (sharedReporter != NULL) {
        [self release];
        return sharedReporter;
    }
    
    /* Initialize our superclass */
    if ((self = [super init]) == nil)
        return nil;

    /* Save application ID and version */
    _applicationIdentifier = [applicationIdentifier retain];
    _applicationVersion = [applicationVersion retain];
    
    /* No occurances of '/' should ever be in a bundle ID, but just to be safe, we escape them */
    NSString *appIdPath = [applicationIdentifier stringByReplacingOccurrencesOfString: @"/" withString: @"_"];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDir = [paths objectAtIndex: 0];
    _crashReportDirectory = [[[cacheDir stringByAppendingPathComponent: PLCRASH_CACHE_DIR] stringByAppendingPathComponent: appIdPath] retain];
    
    return self;
}


/**
 * @internal
 * 
 * Initialize with the provided bundle's ID and version.
 */
- (id) initWithBundle: (NSBundle *) bundle {
    NSString *bundleIdentifier = [bundle bundleIdentifier];
    NSString *bundleVersion = [[bundle infoDictionary] objectForKey: (NSString *) kCFBundleVersionKey];
    
    /* Verify that the identifier is available */
    if (bundleIdentifier == nil) {
        const char *progname = getprogname();
        if (progname == NULL) {
            [NSException raise: PLCrashReporterException format: @"Can not determine process identifier or process name"];
            [self release];
            return nil;
        }

        NSDEBUG(@"Warning -- bundle identifier, using process name %s", progname);
        bundleIdentifier = [NSString stringWithUTF8String: progname];
    }

    /* Verify that the version is available */
    if (bundleVersion == nil) {
        NSDEBUG(@"Warning -- bundle version unavailable");
        bundleVersion = @"";
    }
    
    return [self initWithApplicationIdentifier: bundleIdentifier appVersion: bundleVersion];
}


- (void) dealloc {
    [_crashReportDirectory release];
    [_applicationIdentifier release];
    [_applicationVersion release];
    [super dealloc];
}


/**
 * Validate (and create if necessary) the crash reporter directory structure.
 */
- (BOOL) populateCrashReportDirectoryAndReturnError: (NSError **) outError {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    /* Set up reasonable directory attributes */
    NSDictionary *attributes = [NSDictionary dictionaryWithObject: [NSNumber numberWithUnsignedLong: 0755] forKey: NSFilePosixPermissions];
    
    /* Create the top-level path */
    if (![fm fileExistsAtPath: [self crashReportDirectory]] &&
        ![fm createDirectoryAtPath: [self crashReportDirectory] withIntermediateDirectories: YES attributes: attributes error: outError])
    {
        return NO;
    }

    /* Create the queued crash report directory */
    if (![fm fileExistsAtPath: [self queuedCrashReportDirectory]] &&
        ![fm createDirectoryAtPath: [self queuedCrashReportDirectory] withIntermediateDirectories: YES attributes: attributes error: outError])
    {
        return NO;
    }

    return YES;
}

/**
 * Return the path to the crash reporter data directory.
 */
- (NSString *) crashReportDirectory {
    return _crashReportDirectory;
}


/**
 * Return the path to to-be-sent crash reports.
 */
- (NSString *) queuedCrashReportDirectory {
    return [[self crashReportDirectory] stringByAppendingPathComponent: PLCRASH_QUEUED_DIR];
}


/**
 * Return the path to live crash report (which may not yet, or ever, exist).
 */
- (NSString *) crashReportPath {
    return [[self crashReportDirectory] stringByAppendingPathComponent: PLCRASH_LIVE_CRASHREPORT];
}


#if TARGET_OS_MAC && !TARGET_OS_IPHONE && !TARGET_IPHONE_SIMULATOR
/**
 * Delegate method for NSExceptionHandling.
 */
- (BOOL) exceptionHandler: (NSExceptionHandler *) sender shouldHandleException: (NSException *) exception mask: (unsigned int) mask {
    plcrashreporter_handler_ctx_t context;

    CFUUIDRef UUIDObject = CFUUIDCreate(kCFAllocatorDefault);
    NSString *UUID = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, UUIDObject);
    CFRelease(UUIDObject);
    NSString *filename = [[NSString alloc] initWithFormat:@"%@.plcrash", UUID];
    [UUID release];
    context.path = strdup([[[self crashReportDirectory] stringByAppendingPathComponent: filename] UTF8String]);
    [filename release];

    plcrash_log_writer_init(&context.writer, _applicationIdentifier, _applicationVersion, false);
    plcrash_log_writer_set_exception(&context.writer, exception);

    plcrash_async_file_t file;

    /* Open the output file */
    int fd = open(context.path, O_RDWR|O_CREAT|O_TRUNC, 0644);
    if (fd < 0) {
        PLCF_DEBUG("Could not open the crashlog output file: %s", strerror(errno));
        return YES;
    }

    /* Initialize the output context */
    plcrash_async_file_init(&file, fd, MAX_REPORT_BYTES);

    /* Write the crash log using the already-initialized writer */
    plcrash_log_writer_write(&context.writer, mach_thread_self(), &shared_image_list, &file, nil, nil);
    plcrash_log_writer_close(&context.writer);

    /* Finished */
    plcrash_async_file_flush(&file);
    plcrash_async_file_close(&file);

    return YES;
}
#endif


@end

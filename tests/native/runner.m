// The entry point every native unit binary is linked with: it owns the test
// registry that imp-test.h only declares, runs what registered itself, and
// decides the exit status.
//
// Two binaries are built from this file. One links the Foundation parity probe
// and runs first, the other links the unit tests for src/. They share a runner
// so that a parity failure and an assertion failure read identically in a log,
// and so that the filter argument works the same way on both.

#import "imp-test.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *name;
    IMPTestFunction function;
} IMPTestEntry;

// Fixed storage because IMPTestRegister runs from a constructor, before main
// and before any allocator this file controls is known to be usable. Growing
// past the limit is a build-time fact, not a runtime condition, so it aborts
// with the number rather than silently dropping the tests that did not fit -
// which would leave a suite reporting success for tests it never ran.
enum { IMPTestCapacity = 512 };

static IMPTestEntry gRegisteredTests[IMPTestCapacity];
static size_t gRegisteredCount;

static const char *gRunningTestName;
static size_t gRunningTestFailures;
static size_t gTotalFailures;
static NSMutableArray<NSString *> *gFailureReport;

void IMPTestRegister(const char *name, IMPTestFunction function) {
    if (gRegisteredCount >= (size_t)IMPTestCapacity) {
        fprintf(stderr, "ERROR: more than %d native tests are registered; raise IMPTestCapacity.\n", IMPTestCapacity);
        abort();
    }
    gRegisteredTests[gRegisteredCount].name = name;
    gRegisteredTests[gRegisteredCount].function = function;
    gRegisteredCount++;
}

void IMPTestFail(const char *file, int line, NSString *message) {
    // Printed the moment it happens, so a suite that later crashes still leaves
    // behind everything it had already established. The tail block repeats the
    // failures with the test name attached, which this line cannot carry
    // because a macro has no way to know which test body it expanded into.
    fprintf(stderr, "FAIL: %s:%d: %s\n", file, line, message.UTF8String);
    fflush(stderr);
    [gFailureReport addObject:[NSString stringWithFormat:@"%s: %s:%d: %@", gRunningTestName, file, line, message]];
    gRunningTestFailures++;
    gTotalFailures++;
}

// Constructors run in link order, which changes when the source list is
// reordered. Sorting by name makes a run reproducible and makes a filtered run
// report its tests in the same order the full run did.
static int CompareByName(const void *left, const void *right) {
    return strcmp(((const IMPTestEntry *)left)->name, ((const IMPTestEntry *)right)->name);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        const char *filter = (argc > 1) ? argv[1] : NULL;
        if (filter != NULL && filter[0] == '\0') {
            fprintf(stderr, "ERROR: the test filter is empty; omit it to run every test.\n");
            return 1;
        }

        gFailureReport = [NSMutableArray array];
        qsort(gRegisteredTests, gRegisteredCount, sizeof(gRegisteredTests[0]), CompareByName);

        size_t executed = 0;
        size_t failedTests = 0;
        for (size_t index = 0; index < gRegisteredCount; index++) {
            const IMPTestEntry entry = gRegisteredTests[index];
            if (filter != NULL && strstr(entry.name, filter) == NULL) {
                continue;
            }
            gRunningTestName = entry.name;
            gRunningTestFailures = 0;
            // Each body gets its own pool so that one test cannot hand another
            // an object that is only still alive by accident, and so a leak
            // shows up against the test that made it.
            @autoreleasepool {
                entry.function();
            }
            executed++;
            if (gRunningTestFailures > 0) {
                failedTests++;
            }
            gRunningTestName = NULL;
        }

        // A filter that matches nothing must not report success. A typo in the
        // argument would otherwise look exactly like a clean run of everything.
        if (executed == 0) {
            if (filter != NULL) {
                fprintf(stderr, "ERROR: no native unit test name contains: %s\n", filter);
            } else {
                fprintf(stderr, "ERROR: no native unit tests are registered; the suite would pass vacuously.\n");
            }
            return 1;
        }

        if (gTotalFailures > 0) {
            for (NSString *failure in gFailureReport) {
                fprintf(stderr, "FAIL: %s\n", failure.UTF8String);
            }
            fprintf(stderr, "ERROR: %zu of %zu native unit tests failed (%zu assertion%s).\n", failedTests, executed,
                    gTotalFailures, gTotalFailures == 1 ? "" : "s");
            return 1;
        }

        printf("Native unit tests passed (%zu test%s).\n", executed, executed == 1 ? "" : "s");
        return 0;
    }
}

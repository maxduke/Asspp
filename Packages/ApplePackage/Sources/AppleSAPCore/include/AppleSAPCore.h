#ifndef APPLE_SAP_CORE_H
#define APPLE_SAP_CORE_H

#include <stddef.h>
#include <stdint.h>

/// Same 24-byte hardware block used by ipatool and Apple's SAP entry points.
typedef struct {
    uint32_t length;
    uint8_t bytes[20];
} APSAPHardwareInfo;

typedef struct {
    long (*initialize)(void **context, const APSAPHardwareInfo *hardware);
    long (*exchange)(uint32_t version, const APSAPHardwareInfo *hardware, void *context,
                     const void *input, unsigned long inputLength, void **output,
                     unsigned long *outputLength, long *state);
    long (*sign)(void *context, const void *input, unsigned long inputLength,
                 void **output, unsigned long *outputLength);
    long (*teardown)(void *context);
    long (*dispose)(void *buffer);
} APSAPCoreFunctions;

typedef enum {
    APSAPCoreErrorNone = 0,
    APSAPCoreErrorInvalidArgument,
    APSAPCoreErrorUnavailable,
    APSAPCoreErrorNative,
    APSAPCoreErrorMissingContext,
    APSAPCoreErrorInvalidState,
    APSAPCoreErrorInvalidOutput,
    APSAPCoreErrorAllocation,
} APSAPCoreError;

typedef struct {
    APSAPCoreError error;
    int32_t nativeStatus;
} APSAPCoreResult;

typedef struct {
    void *bytes;
    unsigned long length;
} APSAPCoreOutput;

typedef struct APSAPCoreSession APSAPCoreSession;

APSAPCoreSession *APSAPCoreCreate(const APSAPCoreFunctions *functions,
                                const uint8_t *hardware, size_t hardwareLength,
                                APSAPCoreResult *result);
APSAPCoreResult APSAPCoreExchange(APSAPCoreSession *session, const void *input,
                                 size_t inputLength, APSAPCoreOutput *output);
APSAPCoreResult APSAPCoreSign(APSAPCoreSession *session, const void *input,
                             size_t inputLength, APSAPCoreOutput *output);
void APSAPCoreReleaseOutput(APSAPCoreSession *session, APSAPCoreOutput *output);
/// Sets the caller's pointer to NULL, so cleanup is safe to repeat.
void APSAPCoreDestroy(APSAPCoreSession **session);

#endif

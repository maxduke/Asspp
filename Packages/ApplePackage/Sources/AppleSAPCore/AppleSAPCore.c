#include "AppleSAPCore.h"
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(APSAPHardwareInfo) == 24, "SAP hardware ABI size");
_Static_assert(offsetof(APSAPHardwareInfo, bytes) == 4, "SAP hardware ABI offset");

enum APSAPCorePhase { Initialized, Requested, Ready, Failed };

struct APSAPCoreSession {
    APSAPCoreFunctions functions;
    APSAPHardwareInfo hardware;
    void *context;
    enum APSAPCorePhase phase;
};

static APSAPCoreResult result(APSAPCoreError error, int32_t nativeStatus) {
    return (APSAPCoreResult){error, nativeStatus};
}

APSAPCoreSession *APSAPCoreCreate(const APSAPCoreFunctions *functions,
                                const uint8_t *hardware, size_t hardwareLength,
                                APSAPCoreResult *outcome) {
    if (!outcome) return NULL;
    *outcome = result(APSAPCoreErrorInvalidArgument, 0);
    if (!hardware || hardwareLength == 0 || hardwareLength > 20) return NULL;
    if (!functions || !functions->initialize || !functions->exchange || !functions->sign ||
        !functions->teardown || !functions->dispose) {
        *outcome = result(APSAPCoreErrorUnavailable, 0);
        return NULL;
    }
    APSAPCoreSession *session = calloc(1, sizeof(*session));
    if (!session) {
        *outcome = result(APSAPCoreErrorAllocation, 0);
        return NULL;
    }
    session->functions = *functions;
    session->hardware.length = (uint32_t)hardwareLength;
    memcpy(session->hardware.bytes, hardware, hardwareLength);
    int32_t status = functions->initialize(&session->context, &session->hardware);
    if (status != 0 || !session->context) {
        *outcome = result(status ? APSAPCoreErrorNative : APSAPCoreErrorMissingContext, status);
        APSAPCoreDestroy(&session);
        return NULL;
    }
    session->phase = Initialized;
    *outcome = result(APSAPCoreErrorNone, 0);
    return session;
}

void APSAPCoreReleaseOutput(APSAPCoreSession *session, APSAPCoreOutput *output) {
    if (!session || !output) return;
    if (output->bytes) session->functions.dispose(output->bytes);
    *output = (APSAPCoreOutput){0};
}

static APSAPCoreResult validateOutput(APSAPCoreSession *session, APSAPCoreOutput *output,
                                     int32_t status, int allowEmpty) {
    APSAPCoreError error = APSAPCoreErrorNone;
    if (status != 0) error = APSAPCoreErrorNative;
    else if (output->length > (1u << 20) || (output->length && !output->bytes) ||
             (!allowEmpty && output->length == 0)) error = APSAPCoreErrorInvalidOutput;
    if (error != APSAPCoreErrorNone) {
        session->phase = Failed;
        APSAPCoreReleaseOutput(session, output);
    }
    return result(error, status);
}

APSAPCoreResult APSAPCoreExchange(APSAPCoreSession *session, const void *input,
                                 size_t inputLength, APSAPCoreOutput *output) {
    if (output) *output = (APSAPCoreOutput){0};
    if (!session || !input || !inputLength || inputLength > UINT32_MAX || !output)
        return result(APSAPCoreErrorInvalidArgument, 0);
    if (session->phase != Initialized && session->phase != Requested)
        return result(APSAPCoreErrorInvalidState, 0);
    int finishing = session->phase == Requested;
    // Reserve a full native-long output slot. An older 32-bit-width callee can
    // still write its low word safely on the supported little-endian platforms.
    long state = INT32_MAX;
    int32_t status = session->functions.exchange(200, &session->hardware, session->context,
        input, (uint32_t)inputLength, &output->bytes, &output->length, &state);
    APSAPCoreResult outcome = validateOutput(session, output, status, finishing);
    if (outcome.error != APSAPCoreErrorNone) return outcome;
    if (state != (finishing ? 0 : 1)) {
        session->phase = Failed;
        APSAPCoreReleaseOutput(session, output);
        return result(APSAPCoreErrorInvalidState, 0);
    }
    session->phase = finishing ? Ready : Requested;
    return result(APSAPCoreErrorNone, 0);
}

APSAPCoreResult APSAPCoreSign(APSAPCoreSession *session, const void *input,
                             size_t inputLength, APSAPCoreOutput *output) {
    if (output) *output = (APSAPCoreOutput){0};
    if (!session || !input || !inputLength || inputLength > UINT32_MAX || !output)
        return result(APSAPCoreErrorInvalidArgument, 0);
    if (session->phase != Ready) return result(APSAPCoreErrorInvalidState, 0);
    int32_t status = session->functions.sign(session->context, input, (uint32_t)inputLength,
        &output->bytes, &output->length);
    return validateOutput(session, output, status, 0);
}

void APSAPCoreDestroy(APSAPCoreSession **pointer) {
    if (!pointer || !*pointer) return;
    APSAPCoreSession *session = *pointer;
    *pointer = NULL;
    if (session->context) session->functions.teardown(session->context);
    memset(&session->hardware, 0, sizeof(session->hardware));
    free(session);
}

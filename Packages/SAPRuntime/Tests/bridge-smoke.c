// Exercise the exact C archive ABI used by Objective-C, with no credentials.
#include "AssppSAPRuntime.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

static int last_stage;
static void progress(void *context, int stage) {
    (void)context;
    last_stage = stage;
}
static int sign_payload(const char *cache, unsigned char *body, int size,
                        unsigned char **signature, int *length, int cancel) {
    unsigned char hardware[] = {2, 0, 0, 0, 0, 1};
    unsigned long long operation = AssppSAPNewOperation();
    if (cancel) AssppSAPCancel(operation);
    int phase = 0, detail = 0;
    int result = AssppSAPSign(operation, (char *)cache, hardware, sizeof(hardware), body, size,
                              signature, length, &phase, &detail, progress, NULL);
    if (cancel) {
        if (result == 0 || phase != 10 || *signature || *length) {
            fprintf(stderr, "Cancellation failed: %d/%d\n", phase, detail); return 1;
        }
    } else if (result != 0 || phase != 9 || !*signature || *length <= 0 || last_stage != 9) {
        fprintf(stderr, "Signing failed: %d/%d\n", phase, detail); return 1;
    }
    return 0;
}
int main(int argc, char **argv) {
    const char *cache = argc > 1 ? argv[1] : "/unused-cache";
    unsigned char body[] = {0, 255, '&', '\n', 128, 'a'};
    unsigned char *signature = NULL;
    int length = 0;
    if (sign_payload(cache, body, sizeof(body), &signature, &length, 1)) return 1;
    puts("C archive cancellation passed.");
    if (argc < 2) return 0;
    if (sign_payload(cache, body, sizeof(body), &signature, &length, 0)) return 1;
    unsigned char *second = NULL;
    int second_length = 0;
    body[5] = 'b';
    if (sign_payload(cache, body, sizeof(body), &second, &second_length, 0)) {
        AssppSAPFree(signature); return 1;
    }
    int equal = length == second_length && memcmp(signature, second, (size_t)length) == 0;
    AssppSAPFree(signature);
    AssppSAPFree(second);
    if (equal) { fputs("Different payloads reused a signature.\n", stderr); return 1; }
    puts("Live SAP setup and C archive signing of two binary payloads passed.");
    return 0;
}

#ifndef ASSPP_SAP_RUNTIME_H
#define ASSPP_SAP_RUNTIME_H

// Stable C boundary; implemented by Packages/SAPRuntime, built from source.
// Buffers remain owned by the caller for the duration of the synchronous call.
typedef void (*AssppSAPProgress)(void *context, int stage);
unsigned long long AssppSAPNewOperation(void);
void AssppSAPCancel(unsigned long long operation);
int AssppSAPSign(unsigned long long operation, char *cacheRoot,
                 unsigned char *hardware, int hardwareLength,
                 unsigned char *body, int bodyLength,
                 unsigned char **signature, int *signatureLength,
                 int *stage, int *detail,
                 AssppSAPProgress progress, void *progressContext);
void AssppSAPFree(void *buffer);
#endif

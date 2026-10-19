// Asspp's cancellable C facade for the source-built ipatool SAP interpreter.
package main

/*
#include <stdlib.h>
typedef void (*AssppSAPProgress)(void *context, int stage);
static void asspp_report_progress(AssppSAPProgress callback, void *context, int stage) {
    if (callback) callback(context, stage);
}
*/
import "C"

import (
	"path/filepath"
	"runtime/debug"
	"unsafe"

	"github.com/majd/ipatool/v2/internal/sap"
)

//export AssppSAPNewOperation
func AssppSAPNewOperation() C.ulonglong { return C.ulonglong(newOperation()) }

//export AssppSAPCancel
func AssppSAPCancel(id C.ulonglong) { cancelOperation(uint64(id)) }

//export AssppSAPFree
func AssppSAPFree(buffer unsafe.Pointer) { C.free(buffer) }

//export AssppSAPSign
func AssppSAPSign(id C.ulonglong, cacheRoot *C.char, hardware *C.uchar, hardwareLength C.int,
	body *C.uchar, bodyLength C.int, output **C.uchar, outputLength *C.int,
	stage *C.int, detail *C.int, progress C.AssppSAPProgress, progressContext unsafe.Pointer) (result C.int) {
	result = 1
	if output == nil || outputLength == nil || stage == nil || detail == nil {
		return
	}
	*output, *outputLength, *stage, *detail = nil, 0, 12, 0
	op, ok := takeOperation(uint64(id))
	if !ok {
		return
	}
	defer finishOperation(uint64(id), op)
	defer func() {
		if recover() != nil {
			*stage, *detail, result = 13, 0, 1
		}
	}()
	if cacheRoot == nil || hardware == nil || body == nil {
		return
	}
	cache := C.GoString(cacheRoot)
	if !validInput(cache, int(hardwareLength), int(bodyLength)) {
		return
	}
	report := func(value int) {
		*stage = C.int(value)
		C.asspp_report_progress(progress, progressContext, C.int(value))
	}
	fail := func(err error) {
		phase, code := failureMetadata(op.ctx, err, int(*stage))
		*stage, *detail = C.int(phase), C.int(code)
	}
	report(14)
	select {
	case interpreterSlot <- struct{}{}:
		defer func() { <-interpreterSlot }()
	case <-op.ctx.Done():
		fail(op.ctx.Err())
		return
	}
	// Release the compact asset buffers and guest pages promptly after signing.
	defer debug.FreeOSMemory()
	signer, err := sap.NewSigner(op.ctx, sap.Config{
		SetupURL:       "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy",
		CertificateURL: "https://s.mzstatic.com/sap/setupCert.plist",
		Version:        200,
		HardwareID:     C.GoBytes(unsafe.Pointer(hardware), hardwareLength),
		CacheDirectory: filepath.Join(cache, "apple-assets-macos-27-26A434-arm64-v1"),
		Progress:       report,
	})
	if err != nil {
		fail(err)
		return
	}
	defer signer.Close()
	if err := op.ctx.Err(); err != nil {
		fail(err)
		return
	}
	report(9)
	input := C.GoBytes(unsafe.Pointer(body), bodyLength)
	defer clear(input)
	signature, err := signer.Sign(input)
	if err != nil {
		fail(err)
		return
	}
	if err := op.ctx.Err(); err != nil {
		fail(err)
		return
	}
	*output = (*C.uchar)(C.CBytes(signature))
	*outputLength = C.int(len(signature))
	result = 0
	return
}

func main() {}

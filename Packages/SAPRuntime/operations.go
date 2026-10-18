package main

import (
	"context"
	"errors"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// All operations share one interpreter slot. This also serializes cold asset
// extraction and bounds memory when multiple accounts refresh simultaneously.
var interpreterSlot = make(chan struct{}, 1)
var operations sync.Map
var nextOperation atomic.Uint64

type operation struct {
	ctx     context.Context
	cancel  context.CancelFunc
	started atomic.Bool
}

func newOperation() uint64 {
	id := nextOperation.Add(1)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	operations.Store(id, &operation{ctx: ctx, cancel: cancel})
	return id
}

func cancelOperation(id uint64) {
	if value, ok := operations.Load(id); ok {
		value.(*operation).cancel()
	}
}

func takeOperation(id uint64) (*operation, bool) {
	value, ok := operations.Load(id)
	if !ok {
		return nil, false
	}
	op := value.(*operation)
	return op, op.started.CompareAndSwap(false, true)
}

func finishOperation(id uint64, op *operation) {
	operations.Delete(id)
	op.cancel()
}

func validInput(cache string, hardwareLength, bodyLength int) bool {
	return filepath.IsAbs(cache) && hardwareLength >= 1 && hardwareLength <= 20 && bodyLength >= 1 && bodyLength <= 1<<20
}

// Only numeric, explicitly recognized status fields may leave the runtime.
// Raw errors can contain payloads, paths, URLs or emulated memory addresses.
var statusPattern = regexp.MustCompile(`(?:returned|status) (-?[0-9]{1,10})(?:\b|$)`)

func failureMetadata(ctx context.Context, err error, stage int) (int, int) {
	if errors.Is(ctx.Err(), context.Canceled) {
		return 10, 0
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return 11, 0
	}
	if matches := statusPattern.FindStringSubmatch(err.Error()); len(matches) == 2 {
		if value, parseError := strconv.ParseInt(matches[1], 10, 32); parseError == nil {
			return stage, int(value)
		}
	}
	return stage, 0
}

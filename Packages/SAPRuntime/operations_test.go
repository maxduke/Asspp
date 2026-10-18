package main

import (
	"context"
	"errors"
	"sync"
	"testing"
)

func TestOperationCancellationAndSingleOwner(t *testing.T) {
	id := newOperation()
	cancelOperation(id)
	op, ok := takeOperation(id)
	if !ok || !errors.Is(op.ctx.Err(), context.Canceled) {
		t.Fatal("cancellation before signing was lost")
	}
	if _, twice := takeOperation(id); twice {
		t.Fatal("same operation was taken twice")
	}
	finishOperation(id, op)
	if _, exists := operations.Load(id); exists {
		t.Fatal("finished operation was retained")
	}
}

func TestConcurrentCancellation(t *testing.T) {
	id := newOperation()
	op, _ := takeOperation(id)
	var workers sync.WaitGroup
	for range 16 {
		workers.Go(func() { cancelOperation(id) })
	}
	finishOperation(id, op)
	workers.Wait()
}

func TestInputBounds(t *testing.T) {
	if !validInput("/guest/cache", 6, 512) {
		t.Fatal("valid input rejected")
	}
	for _, input := range []struct {
		path           string
		hardware, body int
	}{
		{"relative", 6, 10}, {"", 6, 10}, {"/cache", 0, 10}, {"/cache", 21, 10},
		{"/cache", 6, 0}, {"/cache", 6, (1 << 20) + 1},
	} {
		if validInput(input.path, input.hardware, input.body) {
			t.Fatal("invalid input accepted", input)
		}
	}
}

func TestFailureMetadataRedactsSecrets(t *testing.T) {
	for _, fixture := range []struct {
		message string
		code    int
	}{
		{"password=secret https://private.example/secret", 0},
		{"SAP initialization returned -42001: secret", -42001},
		{"server returned 403 for https://private.example/secret", 403},
		{"status 99999999999999999999: secret", 0},
	} {
		stage, code := failureMetadata(context.Background(), errors.New(fixture.message), 6)
		if stage != 6 || code != fixture.code {
			t.Fatalf("metadata = %d/%d, expected 6/%d", stage, code, fixture.code)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if stage, _ := failureMetadata(ctx, errors.New("secret"), 6); stage != 10 {
		t.Fatal("cancellation not distinguished")
	}
}

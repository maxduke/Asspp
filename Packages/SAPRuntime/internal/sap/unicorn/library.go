package unicorn

type library struct {
	handle uintptr
	close  func() error
	lookup func(string) uintptr
}

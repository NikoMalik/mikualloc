threads ?= 4


fast:
	@zig build  --release=fast

test:
	@zig build test 


run:
	@./zig-out/bin/bench $(threads)


build:
	@zig build



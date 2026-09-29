CC ?= gcc
CFLAGS ?= -O2 -g -std=c99 -Wall -Wextra -Wpedantic -pthread
CURL_CFLAGS ?= $(shell pkg-config --cflags libcurl 2>/dev/null)
CURL_LIBS ?= $(shell pkg-config --libs libcurl 2>/dev/null)
CPPFLAGS += $(CURL_CFLAGS)
LDLIBS += $(CURL_LIBS)

sbproxy: native/sbproxy.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $< $(LDLIBS)

sbproxy-asan: native/sbproxy.c
	$(CC) -O1 -g -std=c99 -Wall -Wextra -Wpedantic -pthread -fno-omit-frame-pointer \
		-fsanitize=address,undefined $(CPPFLAGS) -o $@ $< $(LDLIBS) -fsanitize=address,undefined

test: sbproxy
	python3 tests/integration_test.py

test-asan: sbproxy-asan
	mv sbproxy sbproxy.release
	cp sbproxy-asan sbproxy
	ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 python3 tests/integration_test.py; status=$$?; \
		mv sbproxy.release sbproxy; exit $$status

clean:
	rm -f sbproxy sbproxy-asan sbproxy.release

.PHONY: clean test test-asan

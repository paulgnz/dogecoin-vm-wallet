// The Rust core's C ABI (core/src/ffi.rs): one JSON call.
#pragma once

// Takes a JSON request {"op": ..., ...}; returns a JSON response, either the
// result or {"error": "..."}. Free it with dwc_free.
char *dwc_call(const char *request);

// Wipes and frees a response from dwc_call.
void dwc_free(char *s);

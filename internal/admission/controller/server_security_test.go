/*
Copyright 2019 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAdmissionBodyLimit(t *testing.T) {
	server := NewAdmissionControllerServer(nil)
	for _, size := range []int{maxBodySizeBytes, maxBodySizeBytes + 1, 2 * maxBodySizeBytes} {
		req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader(bytes.Repeat([]byte("x"), size)))
		response := httptest.NewRecorder()
		server.ServeHTTP(response, req)
		if response.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("body size %d: got HTTP %d, want 413", size, response.Code)
		}
	}
	// Malformed but smaller requests reach JSON decoding and retain HTTP 400.
	response := httptest.NewRecorder()
	server.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/", strings.NewReader("invalid JSON")))
	if response.Code != http.StatusBadRequest {
		t.Fatalf("small malformed body: got HTTP %d, want 400", response.Code)
	}
}

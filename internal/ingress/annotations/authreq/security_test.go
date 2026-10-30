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

package authreq

import (
	"net/http"
	"testing"
)

func TestAuthMethodCannotContainDirectives(t *testing.T) {
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodConnect, http.MethodOptions, http.MethodTrace} {
		if !methodsRegex.MatchString(method) {
			t.Errorf("valid HTTP method %q rejected", method)
		}
	}
	for _, method := range []string{"GET; return 200;", "GET\nPOST", "prefixGET", "GETsuffix", "get", ""} {
		if methodsRegex.MatchString(method) {
			t.Errorf("unsafe HTTP method %q accepted", method)
		}
	}
}

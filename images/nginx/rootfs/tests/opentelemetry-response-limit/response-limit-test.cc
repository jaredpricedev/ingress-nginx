// Copyright 2026 The Kubernetes Authors.
// SPDX-License-Identifier: Apache-2.0

#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <opentelemetry/ext/http/client/curl/http_client_curl.h>

namespace http = opentelemetry::ext::http::client;

bool send_all(int fd, const std::string &data) {
  size_t sent = 0;
  while (sent < data.size()) {
    const ssize_t n = send(fd, data.data() + sent, data.size() - sent, MSG_NOSIGNAL);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    sent += static_cast<size_t>(n);
  }
  return true;
}

void require(bool condition, const char *message) {
  if (!condition) {
    std::perror(message);
    std::exit(2);
  }
}

bool check(size_t body_size, size_t padding_size, bool expected_success) {
  const int listener = socket(AF_INET, SOCK_STREAM, 0);
  require(listener >= 0, "socket");
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  require(bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0, "bind");
  socklen_t length = sizeof(address);
  require(getsockname(listener, reinterpret_cast<sockaddr *>(&address), &length) == 0, "getsockname");
  require(listen(listener, 1) == 0, "listen");
  const pid_t server = fork();
  require(server >= 0, "fork");
  if (server == 0) {
    alarm(10);
    const int connection = accept(listener, nullptr, nullptr);
    if (connection < 0) _exit(2);
    std::string request;
    char buffer[1024];
    while (request.find("\r\n\r\n") == std::string::npos && request.size() < 65536) {
      const ssize_t n = recv(connection, buffer, sizeof(buffer), 0);
      if (n <= 0) _exit(2);
      request.append(buffer, static_cast<size_t>(n));
    }
    const std::string headers = "HTTP/1.1 200 OK\r\nContent-Length: " +
        std::to_string(body_size) + "\r\nX-Padding: " + std::string(padding_size, 'p') +
        "\r\nConnection: close\r\n\r\n";
    if (send_all(connection, headers)) send_all(connection, std::string(body_size, 'x'));
    close(connection);
    close(listener);
    _exit(0);
  }
  close(listener);
  const std::string url = "http://127.0.0.1:" + std::to_string(ntohs(address.sin_port)) + "/";
  http::curl::HttpClientSync client;
  auto result = client.GetNoSsl(url);
  int status = 0;
  require(waitpid(server, &status, 0) == server, "waitpid");
  const bool success = static_cast<bool>(result);
  const bool server_ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
  const bool content_ok = !success || result.GetResponse().GetBody().size() == body_size;
  std::cout << "body=" << body_size << " headers=" << padding_size
            << " success=" << success << " expected=" << expected_success << std::endl;
  return server_ok && content_ok && success == expected_success;
}

int main() {
  setenv("NO_PROXY", "127.0.0.1,localhost", 1);
  setenv("no_proxy", "127.0.0.1,localhost", 1);
  constexpr size_t limit = 4 * 1024 * 1024;
  if (!check(16, 0, true) || !check(limit - 512, 0, true) ||
      !check(limit + 1, 0, false) || !check(limit - 512, 1024, false)) return 1;
  std::cout << "OpenTelemetry HTTP response size regression checks passed." << std::endl;
}

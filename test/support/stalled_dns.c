#include <netdb.h>
#include <unistd.h>

// Child-process-only DNS stub. No external network requests are made.
int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **result) {
  (void)node;
  (void)service;
  (void)hints;
  *result = 0;
  usleep(6000000);
  return EAI_AGAIN;
}

#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>
#include <math.h>

// Note: this is not consistent across CPUs (and hence across threads on multicore machines) 
double timestamp() {
  struct timeval tp;
  gettimeofday(&tp, NULL);
  return ((double) tp.tv_sec) * 1e6 + (double) tp.tv_usec;
}

int server() {
  printf("starting server\n");

  struct addrinfo hints, *res;
  int error, server_socket;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family   = PF_INET;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags    = AI_PASSIVE;

  error = getaddrinfo(NULL, "8080", &hints, &res); 
  if(error) {
    printf("server error: %s\n", gai_strerror(error));
    return -1;
  }

  server_socket = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if(server_socket < 0) {
    printf("server error: could not create socket\n");
    return -1;
  }

  int yes = 1;
  if(setsockopt(server_socket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(int)) < 0) {
    printf("server error: could not set socket options\n");
    return -1;
  }

  if(bind(server_socket, res->ai_addr, res->ai_addrlen) < 0) {
    printf("server error: could not bind to socket\n");
    return -1;
  }

  listen(server_socket, 5);

  int client_socket;
  struct sockaddr_storage client_addr;
  socklen_t addr_size;
  client_socket = accept(server_socket, (struct sockaddr *)&client_addr, &addr_size); 

  for(;;) {
    char* buf = malloc(8);
    ssize_t read = recv(client_socket, buf, 8, 0);
    if(read == 0) {
      free(buf);
      break;
    }
    // printf("server received '%s'\n", buf);
    send(client_socket, buf, 8, 0);
    free(buf);
  }

  freeaddrinfo(res);
  return 0;
}

int client(int pings) {
  printf("starting client\n");
  
  struct addrinfo hints, *res;
  int error, client_socket, i;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family   = PF_INET;
  hints.ai_socktype = SOCK_STREAM;

  error = getaddrinfo("127.0.0.1", "8080", &hints, &res); 
  if(error) {
    printf("client error: %s\n", gai_strerror(error));
    return -1;
  }

  client_socket = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if(client_socket < 0) {
    printf("client error: could not create socket\n");
    return -1;
  }

  if(connect(client_socket, res->ai_addr, res->ai_addrlen) < 0) {
    printf("client error: could not connect: %s\n", strerror(errno));
    return -1;
  }

  for(i = 0; i < pings; i++) {
    double timestamp_before = timestamp();
    
    send(client_socket, "ping123", 8, 0);

    char *buf = malloc(8);
    ssize_t read = recv(client_socket, buf, 8, 0);

    if(read == 0) {
      printf("server exited prematurely\n");
      free(buf);
      break;
    }

    // printf("client received '%s'\n", buf);
    free(buf);
    
    double timestamp_after = timestamp();
    fprintf(stderr, "%i %lf\n", i, timestamp_after - timestamp_before);
  }

  printf("client did %d pings\n", pings);

  freeaddrinfo(res);
  return 0;
}

int usage(int argc, char** argv) {
  printf("usage: %s <number of pings>\n", argv[0]);
  return -1;
}

int main(int argc, char** argv) {
  if(argc != 2) {
    return usage(argc, argv);
  } 

  if(fork() == 0) {
    // TODO: we should wait until we know the server is ready
    int pings = 0;
    sscanf(argv[1], "%d", &pings);
    return client(pings);
  } else {
    return server();
  }
}
